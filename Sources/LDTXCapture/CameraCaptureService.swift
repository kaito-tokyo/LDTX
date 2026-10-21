// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreMedia
import Foundation

public protocol CameraCaptureStreaming: Sendable {
  func startCameraCapture(
    cameraID: String,
    targetWidth: Int,
    targetHeight: Int,
    frameRate: Int,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    configurationHandler: (@Sendable (String) -> Void)?,
    handler: @escaping @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  )

  func stop(completionHandler: @escaping @Sendable () -> Void)
}

// Internal seam for deterministic lifecycle tests; each service owns one manager.
protocol CameraCaptureSessionManaging: Sendable {
  func availableCameras() -> [CameraCaptureSource]
  func start(
    request: CaptureSessionRequest,
    handler: @escaping CaptureSessionManager.SampleHandler,
    failureHandler: @escaping CaptureSessionManager.FailureHandler,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void)
  func stop(completionHandler: @escaping @Sendable () -> Void)
}

extension CaptureSessionManager: CameraCaptureSessionManaging {}

public final class CameraCaptureService: CameraCaptureStreaming, @unchecked Sendable {
  public typealias SampleHandler = @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void
  public typealias ConfigurationHandler = @Sendable (String) -> Void
  public typealias FailureHandler = @Sendable (CaptureSessionRuntimeFailure) -> Void

  private let manager: any CameraCaptureSessionManaging
  private let operations = CaptureOperationQueue()

  public init() { manager = CaptureSessionManager() }

  init(manager: any CameraCaptureSessionManaging) { self.manager = manager }

  public func availableCameras() -> [CameraCaptureSource] {
    manager.availableCameras()
  }

  public func startCameraCapture(
    cameraID: String,
    targetWidth: Int,
    targetHeight: Int,
    frameRate: Int,
    failureHandler: @escaping FailureHandler = { _ in },
    configurationHandler: ConfigurationHandler? = nil,
    handler: @escaping SampleHandler,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    operations.enqueue { [self] finished in
      configurationHandler?("Workspace-owned camera session; prefer 1080p with negotiated cadence.")
      manager.start(
        request: CaptureSessionRequest(videoInputs: [
          CaptureSessionVideoRequest(
            sourceKey: cameraID, deviceID: cameraID,
            targetWidth: targetWidth, targetHeight: targetHeight, frameRate: frameRate)
        ]),
        handler: { sample in handler(sample.sampleBuffer, sample.kind) },
        failureHandler: failureHandler
      ) { result in
        completionHandler(result.mapError(Self.mapError))
        finished()
      }
    }
  }

  /// Completes after queued starts, physical stop, and sample delivery have drained.
  public func stop(completionHandler: @escaping @Sendable () -> Void = {}) {
    operations.enqueue { [self] finished in
      manager.stop {
        completionHandler()
        finished()
      }
    }
  }

  private static func mapError(_ error: Error) -> Error {
    if let error = error as? CameraCaptureServiceError {
      return error
    }
    guard let error = error as? CaptureSessionManagerError else {
      return error
    }

    switch error {
    case .cameraAccessDenied:
      return CameraCaptureServiceError.cameraAccessDenied
    case .videoDeviceNotFound(let cameraID):
      return CameraCaptureServiceError.cameraNotFound(cameraID)
    case .cannotAddInput:
      return CameraCaptureServiceError.cannotAddVideoInput
    case .cannotAddOutput, .cannotAddConnection, .missingInputPort:
      return CameraCaptureServiceError.cannotAddVideoOutput
    case .unsupportedVideoPixelFormat(let format):
      return CameraCaptureServiceError.unsupportedVideoPixelFormat(format)
    case .videoDeviceNotAllowed, .invalidRequest:
      return error
    }
  }
}
