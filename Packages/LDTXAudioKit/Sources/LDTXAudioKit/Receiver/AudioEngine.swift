// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreAudio
import Foundation

public final class AudioEngine: @unchecked Sendable {
  public final class Subscription: @unchecked Sendable {
    fileprivate let engine: AudioEngine
    fileprivate let token: LDTXAudioID
    fileprivate init(engine: AudioEngine, token: LDTXAudioID) {
      self.engine = engine
      self.token = token
    }
    public func cancel() { engine.cancel(self) }
  }

  private let native: OpaquePointer
  private let lock = NSLock()
  private var subscriptions: [LDTXAudioID: Unmanaged<CallbackBox>] = [:]

  public init(hardwareEnabled: Bool = true) {
    guard let native = LDTXAudioCreate(hardwareEnabled) else {
      preconditionFailure("Unable to create audio engine")
    }
    self.native = native
  }

  deinit {
    lock.lock()
    let values = subscriptions.values
    subscriptions.removeAll()
    lock.unlock()
    for value in values { value.release() }
    LDTXAudioDestroy(native)
  }

  public func addInput(uid: String, sampleRate: Double = 48_000, channels: UInt32 = 2) -> LDTXAudioID {
    uid.withCString { LDTXAudioAddInput(native, $0, 0, sampleRate, channels) }
  }

  public func hasActiveInput(uid: String) -> Bool {
    uid.withCString { LDTXAudioHasActiveInput(native, $0) }
  }

  public static func defaultInputUID() -> String? {
    var device = AudioDeviceID(kAudioObjectUnknown)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
      device != kAudioObjectUnknown
    else { return nil }
    var uid: Unmanaged<CFString>?
    address.mSelector = kAudioDevicePropertyDeviceUID
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
      let uid
    else { return nil }
    return uid.takeRetainedValue() as String
  }

  public func subscribe(
    input: LDTXAudioID,
    handler: @escaping @Sendable (CMSampleBuffer) -> Void
  ) -> Subscription {
    let box = CallbackBox(handler)
    let unmanaged = Unmanaged.passRetained(box)
    let token = LDTXAudioSubscribe(native, input, true, { context, sample in
      guard let context, let sample else { return }
      let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
      box.handler(sample)
    }, unmanaged.toOpaque())
    lock.lock()
    subscriptions[token] = unmanaged
    lock.unlock()
    return Subscription(engine: self, token: token)
  }

  private func cancel(_ subscription: Subscription) {
    lock.lock()
    guard let box = subscriptions.removeValue(forKey: subscription.token) else {
      lock.unlock()
      return
    }
    lock.unlock()
    LDTXAudioUnsubscribe(native, subscription.token)
    box.release()
  }

  public func stop() {
    let semaphore = DispatchSemaphore(value: 0)
    LDTXAudioStop(native, { context in
      guard let context else { return }
      Unmanaged<DispatchSemaphore>.fromOpaque(context).takeUnretainedValue().signal()
    }, Unmanaged.passUnretained(semaphore).toOpaque())
    semaphore.wait()
  }

  private final class CallbackBox: @unchecked Sendable {
    let handler: @Sendable (CMSampleBuffer) -> Void
    init(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) { self.handler = handler }
  }
}
