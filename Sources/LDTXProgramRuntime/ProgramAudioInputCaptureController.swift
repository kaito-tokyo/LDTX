// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXCapture
import LDTXProgram

protocol ProgramAudioCaptureStreaming: AnyObject, Sendable {
  func startAudioCapture(
    audioDeviceID: String?,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    handler: @escaping @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  )
  func stop(completionHandler: @escaping @Sendable () -> Void)
}

/// Owns only Workspace capture subscriptions; Hardware ownership stays
/// in `WorkspaceCaptureSessionCoordinator`.
public final class ProgramAudioInputCaptureController: @unchecked Sendable {
  public typealias SampleHandler =
    @Sendable (
      _ channelKey: String,
      _ sampleBuffer: CMSampleBuffer,
      _ kind: CameraCaptureSampleKind
    ) -> Void

  private let lock = NSLock()
  private let captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  private var subscriptions: [WorkspaceCaptureSessionCoordinator.AudioSubscription] = []
  private var generation = 0
  private var restartCompletion: ProgramAudioRestartCompletion?

  public init(captureSessionCoordinator: WorkspaceCaptureSessionCoordinator) {
    self.captureSessionCoordinator = captureSessionCoordinator
  }

  init(makeCaptureService: @escaping @Sendable () -> any ProgramAudioCaptureStreaming) {
    captureSessionCoordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { CameraCaptureService() },
      audioCaptureServiceFactory: makeCaptureService)
  }

  public func restart(
    audioChannels: [ProgramAudioChannel],
    inputAudioDeviceMappings: [String: String],
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    sampleHandler: @escaping SampleHandler,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    let completion = ProgramAudioRestartCompletion(handler: completionHandler)
    let (generation, previousSubscriptions, previousCompletion) = lock.withLock {
      self.generation += 1
      let previousSubscriptions = subscriptions
      let previousCompletion = restartCompletion
      subscriptions = []
      restartCompletion = completion
      return (self.generation, previousSubscriptions, previousCompletion)
    }
    previousCompletion?.finish(.failure(CancellationError()))
    previousSubscriptions.forEach(captureSessionCoordinator.unsubscribeAudio)
    start(
      audioChannels: audioChannels,
      inputAudioDeviceMappings: inputAudioDeviceMappings,
      at: 0,
      generation: generation,
      failureHandler: failureHandler,
      sampleHandler: sampleHandler,
      completion: completion)
  }

  public func stop(completionHandler: @escaping @Sendable () -> Void = {}) {
    let (subscriptions, restartCompletion) = lock.withLock {
      generation += 1
      let subscriptions = self.subscriptions
      let restartCompletion = self.restartCompletion
      self.subscriptions = []
      self.restartCompletion = nil
      return (subscriptions, restartCompletion)
    }
    restartCompletion?.finish(.failure(CancellationError()))
    subscriptions.forEach(captureSessionCoordinator.unsubscribeAudio)
    completionHandler()
  }

  private func start(
    audioChannels: [ProgramAudioChannel],
    inputAudioDeviceMappings: [String: String],
    at index: Int,
    generation: Int,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    sampleHandler: @escaping SampleHandler,
    completion: ProgramAudioRestartCompletion
  ) {
    guard isCurrent(generation) else {
      completion.finish(.failure(CancellationError()))
      return
    }
    guard index < audioChannels.count else {
      completion.finish(.success(()))
      return
    }

    let channel = audioChannels[index]
    guard case .inputAudioDevice = channel.component.definition else {
      start(
        audioChannels: audioChannels,
        inputAudioDeviceMappings: inputAudioDeviceMappings,
        at: index + 1,
        generation: generation,
        failureHandler: failureHandler,
        sampleHandler: sampleHandler,
        completion: completion)
      return
    }
    let mappingKey = audioChannels.inputAudioDeviceMappingKey(for: channel)
    guard let deviceID = inputAudioDeviceMappings[mappingKey], !deviceID.isEmpty else {
      start(
        audioChannels: audioChannels,
        inputAudioDeviceMappings: inputAudioDeviceMappings,
        at: index + 1,
        generation: generation,
        failureHandler: failureHandler,
        sampleHandler: sampleHandler,
        completion: completion)
      return
    }

    let channelKey = audioChannels.audioChannelKey(for: channel)
    let subscription = captureSessionCoordinator.subscribeAudio(
      deviceID: deviceID,
      failureHandler: { [weak self] failure in
        guard self?.isCurrent(generation) == true else { return }
        failureHandler(failure)
      },
      sampleHandler: { [weak self] sampleBuffer in
        guard self?.isCurrent(generation) == true else { return }
        sampleHandler(channelKey, sampleBuffer, .audio)
      },
      completionHandler: { [self] result in
        guard isCurrent(generation) else {
          completion.finish(.failure(CancellationError()))
          return
        }
        switch result {
        case .success:
          start(
            audioChannels: audioChannels,
            inputAudioDeviceMappings: inputAudioDeviceMappings,
            at: index + 1,
            generation: generation,
            failureHandler: failureHandler,
            sampleHandler: sampleHandler,
            completion: completion)
        case .failure(let error):
          stopCurrentGeneration(generation)
          completion.finish(.failure(error))
        }
      })
    let registered = lock.withLock {
      guard self.generation == generation else { return false }
      subscriptions.append(subscription)
      return true
    }
    if !registered {
      captureSessionCoordinator.unsubscribeAudio(subscription)
      completion.finish(.failure(CancellationError()))
    }
  }

  private func isCurrent(_ generation: Int) -> Bool {
    lock.withLock { self.generation == generation }
  }

  private func stopCurrentGeneration(_ generation: Int) {
    let subscriptions: [WorkspaceCaptureSessionCoordinator.AudioSubscription] = lock.withLock {
      guard self.generation == generation else { return [] }
      self.generation += 1
      let subscriptions = self.subscriptions
      self.subscriptions = []
      return subscriptions
    }
    subscriptions.forEach(captureSessionCoordinator.unsubscribeAudio)
  }
}

private final class ProgramAudioRestartCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (Result<Void, any Error>) -> Void)?

  init(handler: @escaping @Sendable (Result<Void, any Error>) -> Void) {
    self.handler = handler
  }

  func finish(_ result: Result<Void, any Error>) {
    let handler = lock.withLock {
      let handler = self.handler
      self.handler = nil
      return handler
    }
    handler?(result)
  }
}
