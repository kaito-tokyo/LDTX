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

extension CameraCaptureService: ProgramAudioCaptureStreaming {}

/// Owns only input-device capture subscriptions. Monitor and Output Session
/// each create their own controller and receive samples through its callback.
public final class ProgramAudioInputCaptureController: @unchecked Sendable {
  public typealias SampleHandler =
    @Sendable (
      _ channelKey: String,
      _ sampleBuffer: CMSampleBuffer,
      _ kind: CameraCaptureSampleKind
    ) -> Void

  private let lock = NSLock()
  private let makeCaptureService: @Sendable () -> any ProgramAudioCaptureStreaming
  private var services: [any ProgramAudioCaptureStreaming] = []
  private var generation = 0
  private var activeStartGroup: DispatchGroup?

  public convenience init() {
    self.init(makeCaptureService: { CameraCaptureService() })
  }

  init(makeCaptureService: @escaping @Sendable () -> any ProgramAudioCaptureStreaming) {
    self.makeCaptureService = makeCaptureService
  }

  public func restart(
    audioChannels: [ProgramAudioChannel],
    inputAudioDeviceMappings: [String: String],
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    sampleHandler: @escaping SampleHandler,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    let startGroup = DispatchGroup()
    let (generation, previousServices, previousStartGroup) = lock.withLock {
      self.generation += 1
      let previousServices = services
      let previousStartGroup = activeStartGroup
      services = []
      activeStartGroup = startGroup
      return (self.generation, previousServices, previousStartGroup)
    }
    stopAndWaitForStarts(previousServices, startGroup: previousStartGroup) { [self] in
      start(
        audioChannels: audioChannels,
        inputAudioDeviceMappings: inputAudioDeviceMappings,
        at: 0,
        generation: generation,
        startGroup: startGroup,
        failureHandler: failureHandler,
        sampleHandler: sampleHandler,
        completionHandler: completionHandler)
    }
  }

  public func stop(completionHandler: @escaping @Sendable () -> Void = {}) {
    let (services, startGroup) = lock.withLock {
      generation += 1
      let services = self.services
      let startGroup = activeStartGroup
      self.services = []
      activeStartGroup = nil
      return (services, startGroup)
    }
    stopAndWaitForStarts(
      services, startGroup: startGroup, completionHandler: completionHandler)
  }

  private func start(
    audioChannels: [ProgramAudioChannel],
    inputAudioDeviceMappings: [String: String],
    at index: Int,
    generation: Int,
    startGroup: DispatchGroup,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    sampleHandler: @escaping SampleHandler,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard isCurrent(generation) else {
      completionHandler(.failure(CancellationError()))
      return
    }
    guard index < audioChannels.count else {
      completionHandler(.success(()))
      return
    }

    let channel = audioChannels[index]
    guard case .inputAudioDevice = channel.component.definition else {
      start(
        audioChannels: audioChannels,
        inputAudioDeviceMappings: inputAudioDeviceMappings,
        at: index + 1,
        generation: generation,
        startGroup: startGroup,
        failureHandler: failureHandler,
        sampleHandler: sampleHandler,
        completionHandler: completionHandler)
      return
    }
    let mappingKey = audioChannels.inputAudioDeviceMappingKey(for: channel)
    guard let deviceID = inputAudioDeviceMappings[mappingKey], !deviceID.isEmpty else {
      start(
        audioChannels: audioChannels,
        inputAudioDeviceMappings: inputAudioDeviceMappings,
        at: index + 1,
        generation: generation,
        startGroup: startGroup,
        failureHandler: failureHandler,
        sampleHandler: sampleHandler,
        completionHandler: completionHandler)
      return
    }

    let channelKey = audioChannels.audioChannelKey(for: channel)
    let service = makeCaptureService()
    let registered = lock.withLock {
      guard self.generation == generation else { return false }
      services.append(service)
      startGroup.enter()
      return true
    }
    guard registered else {
      completionHandler(.failure(CancellationError()))
      return
    }
    service.startAudioCapture(
      audioDeviceID: deviceID,
      failureHandler: { [weak self] failure in
        guard self?.isCurrent(generation) == true else { return }
        failureHandler(failure)
      },
      handler: { [weak self] sampleBuffer, kind in
        guard self?.isCurrent(generation) == true else { return }
        sampleHandler(channelKey, sampleBuffer, kind)
      },
      completionHandler: { [self] result in
        guard isCurrent(generation) else {
          service.stop {
            startGroup.leave()
            completionHandler(.failure(CancellationError()))
          }
          return
        }
        switch result {
        case .success:
          start(
            audioChannels: audioChannels,
            inputAudioDeviceMappings: inputAudioDeviceMappings,
            at: index + 1,
            generation: generation,
            startGroup: startGroup,
            failureHandler: failureHandler,
            sampleHandler: sampleHandler,
            completionHandler: completionHandler)
          startGroup.leave()
        case .failure(let error):
          stopCurrentGeneration(generation) {
            startGroup.leave()
            completionHandler(.failure(error))
          }
        }
      })
  }

  private func isCurrent(_ generation: Int) -> Bool {
    lock.withLock { self.generation == generation }
  }

  private func stopCurrentGeneration(
    _ generation: Int,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    let services: [any ProgramAudioCaptureStreaming] = lock.withLock {
      guard self.generation == generation else { return [] }
      self.generation += 1
      let services = self.services
      self.services = []
      activeStartGroup = nil
      return services
    }
    stop(services, at: 0, completionHandler: completionHandler)
  }

  private func stop(
    _ services: [any ProgramAudioCaptureStreaming],
    at index: Int,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    guard index < services.count else {
      completionHandler()
      return
    }
    services[index].stop { [self] in
      stop(services, at: index + 1, completionHandler: completionHandler)
    }
  }

  private func stopAndWaitForStarts(
    _ services: [any ProgramAudioCaptureStreaming],
    startGroup: DispatchGroup?,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    let completionGroup = DispatchGroup()
    completionGroup.enter()
    stop(services, at: 0) { completionGroup.leave() }
    if let startGroup {
      completionGroup.enter()
      startGroup.notify(queue: .global()) { completionGroup.leave() }
    }
    completionGroup.notify(queue: .global(), execute: completionHandler)
  }
}
