// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreAudio
import Foundation
import LDTXAudioMonitorBuffer
import OSLog
import os

public struct AudioMonitorRoute: Sendable, Equatable {
  public var key: String
  public var deviceUID: String
  public var gain: Float
  public var enabled: Bool

  public init(key: String, deviceUID: String, gain: Float, enabled: Bool) {
    self.key = key
    self.deviceUID = deviceUID
    self.gain = gain
    self.enabled = enabled
  }
}

public struct AudioMonitorStatistics: Sendable {
  public let deviceUID: String
  public let receivedFrames: UInt64
  public let bufferedFrames: UInt32
  public let droppedFrames: UInt64
  public let missingFrames: UInt64
  public let rate: Float
  public let renderErrors: UInt64
}

/// One monitor graph per Workspace, independent of recording and composition clocks.
public final class WorkspaceAudioMonitor: @unchecked Sendable {
  public static let statusDidChange = Notification.Name("LDTXAudioMonitor.statusDidChange")
  private static let failures = OSAllocatedUnfairLock(initialState: [UUID: String]())
  public static var failureMessages: [String] { failures.withLock { Array($0.values).sorted() } }
  private let id = UUID()
  private let defaults: UserDefaults

  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.AudioMonitor.control")
  private let queueKey = DispatchSpecificKey<Bool>()
  private var output: MonitorAudioUnit?
  private var mixer: MonitorAudioUnit?
  private var converters: [MonitorAudioUnit] = []
  private var inputOrder: [String] = []
  private var outputUID = ""
  private var preferencesObserver: NSObjectProtocol?
  private var inputs: [String: HardwareMonitorInput] = [:]
  private var channels: [String: MonitorChannel] = [:]

  private var routes: [AudioMonitorRoute] = []
  private var masterGain: Float = 1
  private var generation: UInt64 = 0
  private var listeners:
    [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
  private let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "AudioMonitor")

  public static let outputDevicePreferenceKey = "tokyo.kaito.ldtx.monitor-output-device-uid"

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    queue.setSpecific(key: queueKey, value: true)
    preferencesObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: nil
    ) { [weak self] _ in
      self?.queue.async { [weak self] in
        guard let self else { return }
        let uid = self.defaults.string(forKey: Self.outputDevicePreferenceKey) ?? ""
        guard uid != self.outputUID else { return }
        self.reconfigureAfterHardwareChange()
      }
    }
  }

  public func configure(routes: [AudioMonitorRoute], masterGain: Float) throws {
    try perform {
      let oldTopology = self.routes.map { [$0.key, $0.deviceUID] }
      let newTopology = routes.map { [$0.key, $0.deviceUID] }
      self.routes = routes
      self.masterGain = masterGain
      if output != nil && oldTopology == newTopology {
        applyGains()
      } else {
        try rebuild()
      }
    }
  }

  public func updateGains(_ gains: [String: Float], enabledKeys: Set<String>, masterGain: Float) {
    perform {
      self.masterGain = masterGain
      for index in routes.indices {
        routes[index].gain = gains[routes[index].key] ?? routes[index].gain
        routes[index].enabled = enabledKeys.contains(routes[index].key)
      }
      applyGains()
    }
  }

  public var channelIdentities: [String: ObjectIdentifier] {
    perform { channels.mapValues { ObjectIdentifier($0) } }
  }

  public var statistics: [AudioMonitorStatistics] {
    perform {
      inputs.map { uid, input in
        AudioMonitorStatistics(
          deviceUID: uid,
          receivedFrames: LDTXMonitorBufferReceived(input.buffer),
          bufferedFrames: LDTXMonitorBufferAvailable(input.buffer),
          droppedFrames: LDTXMonitorBufferDropped(input.buffer),
          missingFrames: LDTXMonitorBufferMissing(input.buffer), rate: 1, renderErrors: LDTXMonitorAURenderErrors(input.context))
      }
    }
  }

  public func stop() {
    perform {
      routes = []
      tearDown()
      reportFailure(nil)
    }
  }

  /// Also used by hardware notifications; keeps reconstruction on the owner queue.
  func refreshHardware() throws {
    try perform { try rebuild() }
  }

  private func perform<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
    return try queue.sync(execute: body)
  }

  private func rebuild() throws {
    tearDown()
    reportFailure(nil)
    outputUID = self.defaults.string(forKey: Self.outputDevicePreferenceKey) ?? ""
    guard !routes.isEmpty, !outputUID.isEmpty else { return }
    watch(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    do {
      guard let device = try AudioHardwareSystem.shared.device(forUID: outputUID) else {
        throw AudioMonitorError.deviceUnavailable(outputUID)
      }
      let output = try MonitorAudioUnit(type: kAudioUnitType_Output, subtype: kAudioUnitSubType_HALOutput)
      self.output = output
      try output.set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(0))
      try output.set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(1))
      try output.set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device.id)
      // Shorten only the selected output device's I/O cycle. Input AUHALs keep
      // their existing device buffer sizes; the ring supports partial reads.
      if try device.bufferFrameSize != 128 {
        try output.set(kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, UInt32(128))
      }
      let outputFrames = try output.get(kAudioDevicePropertyBufferFrameSize,
        kAudioUnitScope_Global, 0, initial: UInt32(0))
      let hardware = try output.get(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                                    initial: AudioStreamBasicDescription())
      guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else {
        throw AudioMonitorError.unsupportedFormat(outputUID)
      }
      let format = monitorPCMFormat(rate: hardware.mSampleRate, channels: min(2, hardware.mChannelsPerFrame))
      let maximum = max(UInt32(4096), UInt32(try device.bufferFrameSize))
      try output.set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, maximum)
      try output.set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, format)
      let mixer = try MonitorAudioUnit(type: kAudioUnitType_Mixer, subtype: kAudioUnitSubType_MultiChannelMixer)
      self.mixer = mixer
      inputOrder = Set(routes.map(\.deviceUID)).sorted()
      try mixer.set(kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, UInt32(inputOrder.count))
      try mixer.set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, maximum)
      try mixer.set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, format)
      for (index, uid) in inputOrder.enumerated() {
        let input = try HardwareMonitorInput(uid: uid)
        inputs[uid] = input
        let inputFrames = try input.capture.get(kAudioDevicePropertyBufferFrameSize,
          kAudioUnitScope_Global, 0, initial: UInt32(0))
        logger.notice("AUHAL monitor input frames=\(inputFrames)")
        let converter = try MonitorAudioUnit(type: kAudioUnitType_FormatConverter, subtype: kAudioUnitSubType_AUConverter)
        converters.append(converter)
        try converter.set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, maximum)
        try converter.set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, input.format)
        try converter.set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, format)
        try checkAudioStatus(LDTXMonitorAUInstallSource(input.context, converter.unit))
        try mixer.set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, UInt32(index), format)
        try converter.connect(to: mixer, bus: UInt32(index))
        try converter.initialize()
        watchDevice(input.device, input: true)
      }
      for route in routes { channels[route.key] = MonitorChannel() }
      try mixer.connect(to: output)
      try mixer.initialize()
      try output.initialize()
      applyGains()
      watchDevice(device, input: false)
      try output.start()
      for input in inputs.values { try input.start() }
      logger.notice("AUHAL monitor started physicalInputs=\(self.inputs.count) routes=\(self.routes.count) outputFrames=\(outputFrames)")
    } catch {
      stopGraph()
      reportFailure("Monitor: \(error.localizedDescription)")
      throw error
    }
  }

  private func reportFailure(_ message: String?) {
    Self.failures.withLock { $0[id] = message }
    NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
  }

  private func watchDevice(_ device: AudioHardwareDevice, input: Bool) {
    watch(device.id, kAudioDevicePropertyDeviceIsAlive)
    watch(device.id, kAudioDevicePropertyNominalSampleRate)
    watch(device.id, kAudioDevicePropertyBufferFrameSize)
    watch(device.id, kAudioDevicePropertyStreamConfiguration,
          scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
  }

  private func applyGains() {
    guard let mixer else { return }
    // Identical physical samples are pulled once. Summing the enabled logical
    // route gains is exactly equivalent to summing their independently gained PCM.
    for (index, uid) in inputOrder.enumerated() {
      let gain = routes.filter { $0.deviceUID == uid && $0.enabled }.reduce(Float(0)) {
        $0 + ($1.gain.isFinite ? max(0, $1.gain) : 0)
      }
      AudioUnitSetParameter(mixer.unit, kMultiChannelMixerParam_Volume,
                            kAudioUnitScope_Input, UInt32(index), gain, 0)
    }
    AudioUnitSetParameter(mixer.unit, kMultiChannelMixerParam_Volume,
                          kAudioUnitScope_Output, 0, masterGain.isFinite ? max(0, masterGain) : 0, 0)
  }

  private func watch(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    let generation = self.generation
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self, self.generation == generation else { return }
      self.reconfigureAfterHardwareChange()
    }
    if AudioObjectAddPropertyListenerBlock(object, &address, queue, listener) == noErr {
      listeners.append((object, address, listener))
    }
  }

  private func reconfigureAfterHardwareChange() {
    guard !routes.isEmpty else { return }
    do { try refreshHardware() } catch {
      logger.error(
        "Monitor device reconfiguration failed: \(String(describing: error), privacy: .public)")
    }
  }

  private func stopGraph() {
    output?.stop()
    for input in inputs.values { input.stop() }
    // Dispose consumers before releasing callback contexts and their rings.
    output = nil
    mixer = nil
    converters = []
    channels = [:]
    inputs = [:]
    inputOrder = []
  }

  private func tearDown() {
    generation &+= 1
    for (object, storedAddress, listener) in listeners {
      var address = storedAddress
      AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
    }
    listeners = []
    stopGraph()
  }

  deinit {
    if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    perform { tearDown(); reportFailure(nil) }
  }
}
