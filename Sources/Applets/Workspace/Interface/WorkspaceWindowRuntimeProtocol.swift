// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCapture
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletModel
import Observation

@MainActor
public protocol WorkspaceWindowRuntimeProtocol: AnyObject, Observable {
  var url: URL? { get }
  var recordingState: WorkspaceRecordingState { get }

  func availableCaptureDevices() -> (
    cameras: [CameraCaptureSource], audioDevices: [AudioCaptureSource]
  )
  func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>, completionHandler: @escaping @Sendable (Set<String>) -> Void)
  func runtime(for role: ProgramCanvasRole) -> ProgramRuntime?
}
