// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import CoreMedia
import Foundation
import LDTXAudioEngine
import LDTXCapture
import LDTXProgram
import OSLog
import os

/// Workspace-owned adapter. All PCM processing and hardware lifetime is native.
public final class WorkspaceAudioEngine: @unchecked Sendable {
  public static let outputDevicePreferenceKey = "tokyo.kaito.ldtx.monitor-output-device-uid"
  public static let statusDidChange = Notification.Name("LDTXAudioEngine.statusDidChange")
  private static let failures = OSAllocatedUnfairLock(initialState: [UUID: [String: String]]())
  public static var failureMessages: [String] {
    failures.withLock { $0.values.flatMap { $0.values }.sorted() }
  }
  let native: OpaquePointer
  private let lock = NSRecursiveLock()
  private let id = UUID()
  private var inputs: [String: UInt64] = [:]
  private var busOwners: [UUID: Bus] = [:]
  private var observer: NSObjectProtocol?
  private var monitorRoutes: [Route] = []
  private var monitorMaster: Float = 1
  private let defaults: UserDefaults
  private let errors: Errors
  private final class Errors {
    let id: UUID
    init(_ id: UUID) { self.id = id }
  }
  struct Route: Equatable {
    var input: UInt64
    var gain: Float
    var connected: Bool
    var value: LDTXAudioRoute { LDTXAudioRoute(input: input, gain: gain, connected: connected) }
  }
  private struct Bus {
    var id: UInt64
    var routes: [Route]
    var master: Float
  }
  public init(hardwareEnabled: Bool = true, defaults: UserDefaults = .standard) {
    guard let native = LDTXAudioCreate(hardwareEnabled) else {
      preconditionFailure("Audio engine allocation failed")
    }
    self.native = native
    self.defaults = defaults
    errors = Errors(id)
    LDTXAudioSetErrorHandler(
      native,
      { context, source, status in
        guard let context, let sourcePointer = source else { return }
        let errors = Unmanaged<Errors>.fromOpaque(context).takeUnretainedValue()
        let source = String(cString: sourcePointer)
        WorkspaceAudioEngine.failures.withLock { values in
          var current = values[errors.id] ?? [:]
          current[source] = status == 0 ? nil : "\(source): Core Audio error \(status)"
          values[errors.id] = current
        }
        NotificationCenter.default.post(name: WorkspaceAudioEngine.statusDidChange, object: nil)
      }, Unmanaged.passUnretained(errors).toOpaque())
    if hardwareEnabled {
      observer = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification,
        object: nil, queue: nil
      ) { [weak self] _ in
        // Never reenter native control from its error callback.
        DispatchQueue.global().async { [weak self] in self?.refreshMonitor() }
      }
    }
  }
  func input(uid: String, kind: UInt32 = 0) -> UInt64 {
    lock.withLock {
      let key = "\(kind):\(uid)"
      if let input = inputs[key] { return input }
      let input = uid.withCString { LDTXAudioAddInput(native, $0, kind, 48_000, 2) }
      inputs[key] = input
      return input
    }
  }
  func synchronizePhysicalInputs(_ uids: Set<String>) {
    lock.withLock {
      for uid in uids { _ = input(uid: uid) }
      let removed = inputs.filter {
        $0.key.hasPrefix("0:") && !uids.contains(String($0.key.dropFirst(2)))
      }
      for (key, id) in removed {
        LDTXAudioRemoveInput(native, id)
        inputs[key] = nil
      }
    }
  }
  func routes(
    channels: [ProgramAudioChannel], mappings: [String: String], preferences: ProgramPreferences
  ) -> [Route] {
    channels.compactMap { channel in
      let key = channels.audioChannelKey(for: channel)
      let inputID: UInt64
      var connected = true
      switch channel.component.definition {
      case .inputAudioDevice:
        guard let uid = mappings[channels.inputAudioDeviceMappingKey(for: channel)], !uid.isEmpty
        else { return nil }
        inputID = input(uid: uid)
        if case .inputAudioDevice(let payload) = channel.component, let name = payload.inputDeviceID
        {
          connected = !preferences.isAudioMuted(inputDeviceName: name)
        }
      case .testPatternAudio: inputID = input(uid: key, kind: 1)
      case .silentAudio: inputID = input(uid: key, kind: 2)
      }
      return Route(
        input: inputID, gain: Float(preferences.audioChannelGain(for: channel, in: channels)),
        connected: connected)
    }
  }
  @discardableResult
  func configureBus(owner: UUID, routes: [Route], master: Float) -> UInt64 {
    lock.withLock {
      if let match = busOwners.values.first(where: { $0.routes == routes && $0.master == master }) {
        let previous = busOwners.updateValue(match, forKey: owner)
        releaseIfUnused(previous?.id)
        return match.id
      }
      let previous = busOwners.removeValue(forKey: owner)
      let shared = previous.map { old in busOwners.values.contains { $0.id == old.id } } ?? true
      let busID = shared ? LDTXAudioCreateBus(native) : previous!.id
      let values = routes.map(\.value)
      values.withUnsafeBufferPointer {
        LDTXAudioConfigureBus(native, busID, $0.baseAddress, UInt32($0.count), master)
      }
      busOwners[owner] = Bus(id: busID, routes: routes, master: master)
      return busID
    }
  }
  private func releaseIfUnused(_ bus: UInt64?) {
    if let bus, !busOwners.values.contains(where: { $0.id == bus }) {
      LDTXAudioRemoveBus(native, bus)
    }
  }
  func releaseBus(owner: UUID) {
    lock.withLock { releaseIfUnused(busOwners.removeValue(forKey: owner)?.id) }
  }
  func configureMonitor(routes: [Route], master: Float) {
    lock.withLock {
      monitorRoutes = routes
      monitorMaster = master
      refreshMonitor()
    }
  }
  private func refreshMonitor() {
    lock.withLock {
      let values = monitorRoutes.map(\.value)
      (defaults.string(forKey: Self.outputDevicePreferenceKey) ?? "").withCString { uid in
        values.withUnsafeBufferPointer {
          LDTXAudioConfigureMonitor(native, uid, $0.baseAddress, UInt32($0.count), monitorMaster)
        }
      }
    }
  }
  func subscribe(
    source: UInt64, raw: Bool, waitsForVideo: Bool = false,
    handler: @escaping @Sendable (CMSampleBuffer) -> Void
  ) -> AudioEngineSubscription {
    AudioEngineSubscription(
      engine: self, source: source, raw: raw, waitsForVideo: waitsForVideo, handler: handler)
  }
  func peak(source: UInt64, raw: Bool) -> Float { LDTXAudioConsumePeak(native, source, raw) }
  public func stop(completion: @escaping @Sendable () -> Void) {
    // The worker fences callbacks and tears down HAL before completion.
    let box = Completion(completion)
    LDTXAudioStop(
      native,
      { context in
        guard let context else { return }
        Unmanaged<Completion>.fromOpaque(context).takeRetainedValue().handler()
      }, Unmanaged.passRetained(box).toOpaque())
    lock.withLock {
      inputs = [:]
      busOwners = [:]
      monitorRoutes = []
    }
  }
  private final class Completion {
    let handler: @Sendable () -> Void
    init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
  }
  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    LDTXAudioSetErrorHandler(native, nil, nil)
    LDTXAudioDestroy(native)
    _ = Self.failures.withLock { $0.removeValue(forKey: id) }
  }
}

final class AudioEngineSubscription: @unchecked Sendable {
  private let engine: WorkspaceAudioEngine
  private let context: UnsafeMutableRawPointer
  private let token: UInt64
  private final class Handler {
    let call: @Sendable (CMSampleBuffer) -> Void
    init(_ call: @escaping @Sendable (CMSampleBuffer) -> Void) { self.call = call }
  }
  init(
    engine: WorkspaceAudioEngine, source: UInt64, raw: Bool, waitsForVideo: Bool,
    handler: @escaping @Sendable (CMSampleBuffer) -> Void
  ) {
    self.engine = engine
    context = Unmanaged.passRetained(Handler(handler)).toOpaque()
    let callback: LDTXAudioSampleHandler = { context, sample in
      guard let context, let sample else { return }
      Unmanaged<Handler>.fromOpaque(context).takeUnretainedValue().call(sample)
    }
    token =
      waitsForVideo
      ? LDTXAudioSubscribeAtVideoBoundary(engine.native, source, callback, context)
      : LDTXAudioSubscribe(engine.native, source, raw, callback, context)
  }
  func noteVideoBoundary(_ pts: CMTime) {
    LDTXAudioSetVideoBoundary(engine.native, token, pts)
  }
  func switchSource(_ source: UInt64) {
    LDTXAudioSwitchSubscriptionSource(engine.native, token, source)
  }
  func cancel() {
    // Every caller must fence the worker, even if another caller already
    // requested cancellation but is still waiting for an active notification.
    LDTXAudioUnsubscribe(engine.native, token)
  }
  deinit {
    cancel()
    Unmanaged<Handler>.fromOpaque(context).release()
  }
}

/// Raw subscriber adapter used by existing recording and spectrogram clients.
final class NativeAudioCapture: ProgramAudioCaptureStreaming, @unchecked Sendable {
  private let engine: WorkspaceAudioEngine
  private var subscription: AudioEngineSubscription?
  init(engine: WorkspaceAudioEngine) { self.engine = engine }
  func startAudioCapture(
    audioDeviceID: String?,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    handler: @escaping @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard let audioDeviceID, !audioDeviceID.isEmpty else {
      completionHandler(.failure(CancellationError()))
      return
    }
    let id = engine.input(uid: audioDeviceID)
    subscription = engine.subscribe(source: id, raw: true) { handler($0, .audio) }
    completionHandler(.success(()))
  }
  func stop(completionHandler: @escaping @Sendable () -> Void) {
    subscription?.cancel()
    subscription = nil
    completionHandler()
  }
}
