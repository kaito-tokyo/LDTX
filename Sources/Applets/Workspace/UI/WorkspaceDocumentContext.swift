// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXWorkspaceBundleFormat

/// The document information needed by Workspace UI, independent of its persistence API.
@MainActor
public protocol WorkspaceDocumentContext: AnyObject {
  var fileURL: URL? { get }
  var runtimeWorkspace: WorkspaceV4Bundle? { get }
}

extension WorkspaceDocumentContext {
  public var runtimeWorkspace: WorkspaceV4Bundle? { nil }
}
