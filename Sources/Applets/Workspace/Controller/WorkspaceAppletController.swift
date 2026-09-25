// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Operations exposed by a Workspace window controller to its host.
@MainActor
public protocol WorkspaceAppletController: AnyObject {
  var isRecording: Bool { get }
  var isClosing: Bool { get }

  func save()
  func saveAs()
  func reload()
  func toggleInspector(_ sender: Any?)
  func confirmTermination() -> Bool
  func cancelTerminationConfirmation()
  func closeWorkspace() async
}
