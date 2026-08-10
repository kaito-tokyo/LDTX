// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreMedia
import Foundation

public protocol CameraCaptureStreaming: Sendable {
  func startCameraCapture(
    cameraID: String,
    audioDeviceID: String?,
    targetWidth: Int,
    targetHeight: Int,
    frameRate: Int,
    capturesAudio: Bool,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    configurationHandler: (@Sendable (String) -> Void)?,
    handler: @escaping @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  )

  func stop(completionHandler: @escaping @Sendable () -> Void)
}

public final class CameraCaptureService: CameraCaptureStreaming, @unchecked Sendable {
  public typealias SampleHandler = @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void
  public typealias ConfigurationHandler = @Sendable (String) -> Void
  public typealias FailureHandler = @Sendable (CaptureSessionRuntimeFailure) -> Void

  private static let registry = SharedCaptureSessionRegistry.shared

  private let stateLock = NSLock()
  private var subscriptionIDs: [UUID] = []

  public init() {}

  public func availableCameras() -> [CameraCaptureSource] {
    CaptureSessionManager().availableCameras()
  }

  public func availableAudioDevices() -> [AudioCaptureSource] {
    CaptureSessionManager().availableAudioDevices()
  }

  public func startCameraCapture(
    cameraID: String,
    audioDeviceID: String? = nil,
    targetWidth: Int,
    targetHeight: Int,
    frameRate: Int,
    capturesAudio: Bool = true,
    failureHandler: @escaping FailureHandler = { _ in },
    configurationHandler: ConfigurationHandler? = nil,
    handler: @escaping SampleHandler,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard availableCameras().contains(where: { $0.id == cameraID }) else {
      completionHandler(.failure(CameraCaptureServiceError.cameraNotFound(cameraID)))
      return
    }

    let videoDemand = SharedCaptureSessionVideoDemand(
      deviceID: cameraID,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      frameRate: frameRate
    )
    var demands: [SharedCaptureSessionSubscriptionDemand] = [
      SharedCaptureSessionSubscriptionDemand(video: videoDemand)
    ]

    if capturesAudio {
      let availableAudioDevices = availableAudioDevices()
      let resolvedAudioDeviceID: String
      do {
        resolvedAudioDeviceID = try Self.resolveAudioDeviceID(
          requestedAudioDeviceID: audioDeviceID,
          availableAudioDevices: availableAudioDevices
        )
      } catch {
        completionHandler(.failure(error))
        return
      }
      let captureManager = CaptureSessionManager()
      if captureManager.areLinked(videoDeviceID: cameraID, audioDeviceID: resolvedAudioDeviceID) {
        demands = [
          SharedCaptureSessionSubscriptionDemand(
            video: videoDemand,
            audioDeviceID: resolvedAudioDeviceID
          )
        ]
        configurationHandler?("Capture subscription prepared as one linked video/audio session.")
      } else {
        demands = [
          SharedCaptureSessionSubscriptionDemand(video: videoDemand),
          SharedCaptureSessionSubscriptionDemand(audioDeviceID: resolvedAudioDeviceID),
        ]
        configurationHandler?(
          "Capture subscription prepared as separate video/audio sessions because devices are not linked."
        )
      }
    } else {
      configurationHandler?("Capture subscription prepared as a video-only session.")
    }

    replaceSubscriptions(
      with: demands,
      failureHandler: failureHandler,
      handler: handler,
      completionHandler: completionHandler
    )
  }

  public func startAudioCapture(
    audioDeviceID: String? = nil,
    failureHandler: @escaping FailureHandler = { _ in },
    handler: @escaping SampleHandler,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    let resolvedAudioDeviceID: String
    do {
      resolvedAudioDeviceID = try Self.resolveAudioDeviceID(
        requestedAudioDeviceID: audioDeviceID,
        availableAudioDevices: availableAudioDevices()
      )
    } catch {
      completionHandler(.failure(error))
      return
    }
    replaceSubscriptions(
      with: [SharedCaptureSessionSubscriptionDemand(audioDeviceID: resolvedAudioDeviceID)],
      failureHandler: failureHandler,
      handler: handler,
      completionHandler: completionHandler
    )
  }

  public func stop(completionHandler: @escaping @Sendable () -> Void = {}) {
    let ids = stateLock.withLock { () -> [UUID] in
      let ids = subscriptionIDs
      subscriptionIDs = []
      return ids
    }
    Self.registry.unregister(ids: ids, completionHandler: completionHandler)
  }

  private func replaceSubscriptions(
    with demands: [SharedCaptureSessionSubscriptionDemand],
    failureHandler: @escaping FailureHandler = { _ in },
    handler: @escaping SampleHandler,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    let previousIDs = stateLock.withLock { () -> [UUID] in
      let ids = subscriptionIDs
      subscriptionIDs = []
      return ids
    }
    Self.registry.replace(
      ids: previousIDs,
      with: demands.map { demand in
        SharedCaptureSessionRegistry.PendingSubscription(
          demand: demand,
          failureHandler: failureHandler,
          handler: handler
        )
      }
    ) { [self] result in
      switch result {
      case .success(let newIDs):
        stateLock.withLock {
          subscriptionIDs = newIDs
        }
        completionHandler(.success(()))
      case .failure(let error):
        completionHandler(.failure(Self.mapError(error, for: demands)))
      }
    }
  }

  private static func resolveAudioDeviceID(
    requestedAudioDeviceID: String?,
    availableAudioDevices: [AudioCaptureSource]
  ) throws -> String {
    if let requestedAudioDeviceID {
      guard availableAudioDevices.contains(where: { $0.id == requestedAudioDeviceID }) else {
        throw CameraCaptureServiceError.audioDeviceNotFound(requestedAudioDeviceID)
      }
      return requestedAudioDeviceID
    }

    guard let defaultAudioDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID,
      availableAudioDevices.contains(where: { $0.id == defaultAudioDeviceID })
    else {
      throw CameraCaptureServiceError.cannotAddAudioInput
    }
    return defaultAudioDeviceID
  }

  private static func mapError(
    _ error: Error,
    for demands: [SharedCaptureSessionSubscriptionDemand]
  ) -> Error {
    if let error = error as? CameraCaptureServiceError {
      return error
    }
    guard let error = error as? CaptureSessionManagerError else {
      return error
    }

    switch error {
    case .cameraAccessDenied:
      return CameraCaptureServiceError.cameraAccessDenied
    case .microphoneAccessDenied:
      return CameraCaptureServiceError.microphoneAccessDenied
    case .videoDeviceNotFound(let cameraID):
      return CameraCaptureServiceError.cameraNotFound(cameraID)
    case .audioDeviceNotFound(let audioDeviceID):
      return CameraCaptureServiceError.audioDeviceNotFound(audioDeviceID)
    case .cannotAddInput(let deviceID):
      if demands.contains(where: { $0.audioDeviceID == deviceID }) {
        return CameraCaptureServiceError.cannotAddAudioInput
      }
      return CameraCaptureServiceError.cannotAddVideoInput
    case .cannotAddOutput(let sourceKey),
      .cannotAddConnection(let sourceKey),
      .missingInputPort(let sourceKey):
      if sourceKey.hasPrefix("audio:") {
        return CameraCaptureServiceError.cannotAddAudioOutput
      }
      return CameraCaptureServiceError.cannotAddVideoOutput
    case .unsupportedVideoPixelFormat(let format):
      return CameraCaptureServiceError.unsupportedVideoPixelFormat(format)
    case .videoDeviceNotAllowed,
      .audioDeviceNotAllowed,
      .audioFormatDidNotStabilize,
      .invalidRequest:
      return error
    }
  }
}
