// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreMedia
import Foundation

public enum CameraCaptureSampleKind: Sendable, Equatable, Hashable {
  case video
}

public enum CameraCaptureServiceError: Error, Equatable, LocalizedError {
  case cameraAccessDenied
  case cameraNotFound(String)
  case cannotAddVideoInput
  case cannotAddVideoOutput
  case unsupportedVideoPixelFormat(String)

  public var errorDescription: String? {
    switch self {
    case .cameraAccessDenied:
      "Camera access was not granted."
    case .cameraNotFound(let cameraID):
      "Camera \(cameraID) was not found."
    case .cannotAddVideoInput:
      "The selected camera could not be added to the capture session."
    case .cannotAddVideoOutput:
      "Video sample output could not be added to the capture session."
    case .unsupportedVideoPixelFormat(let pixelFormat):
      "The capture output does not support the required video pixel format: \(pixelFormat)."
    }
  }
}
