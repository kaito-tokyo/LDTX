// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import CoreMedia
import Foundation
import LDTXCapture
import LDTXProgram

protocol ProgramMainAudioMixing: AnyObject, Sendable {
  func start(
    audioChannels: [ProgramAudioChannel], inputAudioDeviceMappings: [String: String],
    programPreferences: ProgramPreferences,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void)
  func addMainAudioMixHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) -> UUID
  func removeMainAudioMixHandler(id: UUID)
  func updateGains(audioChannels: [ProgramAudioChannel], programPreferences: ProgramPreferences)
  func noteVideoPresentationTime(_ presentationTime: CMTime)
  func stop(completionHandler: @escaping @Sendable () -> Void)
}

/// Output owns subscriptions and its video boundary, never physical input.
final class ProgramMainAudioMixer: ProgramMainAudioMixing, @unchecked Sendable {
  private let engine: WorkspaceAudioEngine
  private let owner = UUID()
  private let lock = NSLock()
  private var mappings: [String: String] = [:]
  private var bus: UInt64?
  private var subscription: AudioEngineSubscription?
  private var handlers: [UUID: @Sendable (CMSampleBuffer) -> Void] = [:]
  init(captureSessionCoordinator: WorkspaceCaptureSessionCoordinator) {
    engine = captureSessionCoordinator.audioEngine
  }
  func start(
    audioChannels: [ProgramAudioChannel], inputAudioDeviceMappings: [String: String],
    programPreferences: ProgramPreferences,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    mappings = inputAudioDeviceMappings
    updateGains(audioChannels: audioChannels, programPreferences: programPreferences)
    completionHandler(.success(()))
  }
  func updateGains(audioChannels: [ProgramAudioChannel], programPreferences: ProgramPreferences) {
    let next = engine.configureBus(
      owner: owner,
      routes: engine.routes(
        channels: audioChannels, mappings: mappings, preferences: programPreferences),
      master: Float(programPreferences.masterVolume))
    guard next != bus else { return }
    bus = next
    if let subscription = lock.withLock({ subscription }) {
      subscription.switchSource(next)
      return
    }
    let created = engine.subscribe(source: next, raw: false, waitsForVideo: true) {
      [weak self] sample in
      guard let self else { return }
      let callbacks = self.lock.withLock { Array(self.handlers.values) }
      for callback in callbacks { callback(sample) }
    }
    lock.withLock { subscription = created }
  }
  func addMainAudioMixHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) -> UUID {
    lock.withLock {
      let id = UUID()
      handlers[id] = handler
      return id
    }
  }
  func removeMainAudioMixHandler(id: UUID) {
    _ = lock.withLock { handlers.removeValue(forKey: id) }
  }
  func noteVideoPresentationTime(_ presentationTime: CMTime) {
    guard presentationTime.isNumeric else { return }
    lock.withLock { subscription }?.noteVideoBoundary(presentationTime)
  }
  func stop(completionHandler: @escaping @Sendable () -> Void) {
    let previous = lock.withLock {
      let previous = subscription
      subscription = nil
      return previous
    }
    previous?.cancel()
    bus = nil
    engine.releaseBus(owner: owner)
    lock.withLock { handlers = [:] }
    completionHandler()
  }
}
