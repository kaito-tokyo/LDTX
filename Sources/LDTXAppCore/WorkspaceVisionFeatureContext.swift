// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXTaskQueue
import LDTXWorkspace

@MainActor
public struct WorkspaceVisionFeatureContext {
  public var isSessionRunning: () -> Bool
  public var visionNamed: (String) -> WorkspaceVisionDefinition?
  public var frameForVision: (WorkspaceVisionDefinition) throws -> WorkspaceVisionAnalysisFrame
  public var recordingPackageDirectory: () -> URL?
  public var recordingTimelineMilliseconds: () -> UInt64?
  public var presentRecordingFailure: (Error) -> Void
  public var appendLog: (String) -> Void

  public init(
    isSessionRunning: @escaping () -> Bool,
    visionNamed: @escaping (String) -> WorkspaceVisionDefinition?,
    frameForVision: @escaping (WorkspaceVisionDefinition) throws -> WorkspaceVisionAnalysisFrame,
    recordingPackageDirectory: @escaping () -> URL?,
    recordingTimelineMilliseconds: @escaping () -> UInt64?,
    presentRecordingFailure: @escaping (Error) -> Void,
    appendLog: @escaping (String) -> Void
  ) {
    self.isSessionRunning = isSessionRunning
    self.visionNamed = visionNamed
    self.frameForVision = frameForVision
    self.recordingPackageDirectory = recordingPackageDirectory
    self.recordingTimelineMilliseconds = recordingTimelineMilliseconds
    self.presentRecordingFailure = presentRecordingFailure
    self.appendLog = appendLog
  }
}

public struct WorkspaceVisionAnalysisFrame {
  public var image: CIImage

  public init(image: CIImage) {
    self.image = image
  }
}

public enum WorkspaceVisionFeatureError: LocalizedError {
  case unavailable
  case sessionNotRunning
  case referencedInputDeviceMissing
  case inputDeviceHasNoPhysicalCamera
  case frameUnavailable
  case framePoolBusy
  case invalidSourceCrop
  case definitionChanged

  public var errorDescription: String? {
    switch self {
    case .unavailable: "Vision is unavailable in this app target."
    case .sessionNotRunning: "Vision analysis requires a running Session."
    case .referencedInputDeviceMissing: "The referenced input device is missing."
    case .inputDeviceHasNoPhysicalCamera: "The input device has no physical camera selected."
    case .frameUnavailable: "No video frame is currently available."
    case .framePoolBusy: "The Vision frame pool is busy."
    case .invalidSourceCrop: "Vision crop must leave part of the source image visible."
    case .definitionChanged: "The Vision definition changed while analysis was running."
    }
  }
}
