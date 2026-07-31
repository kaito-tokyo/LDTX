// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXTaskQueue
import LDTXWorkspace

@MainActor
struct WorkspaceVisionFeatureContext {
  var isSessionRunning: () -> Bool
  var visionNamed: (String) -> WorkspaceVisionDefinition?
  var frameForVision: (WorkspaceVisionDefinition) throws -> WorkspaceVisionAnalysisFrame
  var recordingPackageDirectory: () -> URL?
  var recordingTimelineMilliseconds: () -> UInt64?
  var presentRecordingFailure: (Error) -> Void
  var appendLog: (String) -> Void
}

struct WorkspaceVisionAnalysisFrame {
  var image: CIImage
}

enum WorkspaceVisionFeatureError: LocalizedError {
  case unavailable
  case sessionNotRunning
  case referencedInputDeviceMissing
  case inputDeviceHasNoPhysicalCamera
  case frameUnavailable
  case framePoolBusy
  case invalidSourceCrop
  case definitionChanged

  var errorDescription: String? {
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
