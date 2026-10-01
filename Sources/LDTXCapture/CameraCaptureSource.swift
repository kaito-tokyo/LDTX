// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreMedia
import Foundation

public struct CameraCaptureSource: Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var deviceType: String
  public var modelID: String
  public var width: Int
  public var height: Int
  public var isExternal: Bool
  public var formatSummary: String
  public var linkedDeviceIDs: [String]

  public init(
    id: String,
    name: String,
    deviceType: String,
    modelID: String,
    width: Int,
    height: Int,
    isExternal: Bool,
    formatSummary: String,
    linkedDeviceIDs: [String] = []
  ) {
    self.id = id
    self.name = name
    self.deviceType = deviceType
    self.modelID = modelID
    self.width = width
    self.height = height
    self.isExternal = isExternal
    self.formatSummary = formatSummary
    self.linkedDeviceIDs = linkedDeviceIDs
  }
}

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
