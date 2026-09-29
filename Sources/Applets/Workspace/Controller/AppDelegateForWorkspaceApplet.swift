// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit

@MainActor
public protocol AppDelegateForWorkspaceApplet: AnyObject {
  func retain(workspaceAppletController: WorkspaceAppletController)
  func release(workspaceAppletController: WorkspaceAppletController)
}
