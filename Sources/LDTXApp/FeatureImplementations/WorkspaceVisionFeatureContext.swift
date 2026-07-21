// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXTaskQueue
import LDTXWorkspace

@MainActor
struct WorkspaceVisionFeatureContext {
  var visionNamed: (String) -> WorkspaceVisionDefinition?
  var automationNamed: (String) -> WorkspaceAutomationDefinition?
  var imageForVision: (WorkspaceVisionDefinition) throws -> CIImage
  var recordingPackageDirectory: () -> URL?
  var submitAutomation: (WorkspaceAutomationDefinition, SessionTaskSubmission) -> Void
  var appendLog: (String) -> Void
}

enum WorkspaceVisionFeatureError: LocalizedError {
  case unavailable
  case referencedInputDeviceMissing
  case inputDeviceHasNoPhysicalCamera
  case frameUnavailable
  case framePoolBusy
  case definitionChanged

  var errorDescription: String? {
    switch self {
    case .unavailable: "Vision is unavailable in this app target."
    case .referencedInputDeviceMissing: "The referenced input device is missing."
    case .inputDeviceHasNoPhysicalCamera: "The input device has no physical camera selected."
    case .frameUnavailable: "No video frame is currently available."
    case .framePoolBusy: "The Vision frame pool is busy."
    case .definitionChanged: "The Vision definition changed while analysis was running."
    }
  }
}
