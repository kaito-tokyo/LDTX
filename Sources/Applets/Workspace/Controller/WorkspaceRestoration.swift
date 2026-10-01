// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletUI

@MainActor
public protocol WorkspaceWindowRestoring: AnyObject {
  func restoreWorkspaceWindow(
    at url: URL, inspectorSelector: WorkspaceInspectorSelector
  ) throws -> NSWindow
}

@MainActor
public final class WorkspaceRestoration: NSObject, NSWindowRestoration {
  private static let workspaceURLKey = "tokyo.kaito.ldtx.LDTX.WorkspaceAppletController.v1.url"
  private static let inspectorSelectorKey =
    "tokyo.kaito.ldtx.LDTX.WorkspaceAppletController.v1.inspector"

  enum RestorationError: Error {
    case missingWorkspaceURL
    case missingWorkspaceRestorer
  }

  static func encodeRestorableState(
    representedURL: URL?, inspectorSelector: WorkspaceInspectorSelector?, with coder: NSCoder
  ) {
    coder.encode(representedURL as NSURL?, forKey: workspaceURLKey)
    guard let inspectorSelector else { return }
    coder.encode(inspectorSelector.asRepresentation(), forKey: inspectorSelectorKey)
  }

  public static func findWorkspaceWindow(for url: URL) -> NSWindow? {
    NSApplication.shared.windows.first { window in
      guard window.restorationClass == Self.self,
        let representedURL = window.representedURL
      else { return false }
      return identifiesSamePackage(url, representedURL)
    }
  }

  public static func restoreWindow(
    withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder
  ) async throws -> NSWindow {
    guard
      let decodedURL = state.decodeObject(
        of: NSURL.self,
        forKey: workspaceURLKey) as URL?
    else {
      throw RestorationError.missingWorkspaceURL
    }

    let url = decodedURL.standardizedFileURL
    if let workspaceWindow = findWorkspaceWindow(for: url) {
      workspaceWindow.identifier = identifier
      return workspaceWindow
    }

    let selector =
      decodeInspectorSelector(from: state)
      ?? .init(kind: .programVideoLayers)
    guard let restorer = NSApplication.shared.delegate as? any WorkspaceWindowRestoring else {
      throw RestorationError.missingWorkspaceRestorer
    }
    let window = try restorer.restoreWorkspaceWindow(at: url, inspectorSelector: selector)
    window.identifier = identifier
    return window
  }

  private static func decodeInspectorSelector(from coder: NSCoder) -> WorkspaceInspectorSelector? {
    guard
      let representation = coder.decodeObject(
        of: WorkspaceInspectorSelectorRepresentation.self,
        forKey: inspectorSelectorKey)
    else { return nil }
    return representation.selector
  }

  private static func identifiesSamePackage(_ lhs: URL, _ rhs: URL) -> Bool {
    func fileResourceIdentifier(_ url: URL) -> NSObject? {
      guard
        let identifier = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
          .fileResourceIdentifier
      else { return nil }
      return identifier as? NSObject
    }

    guard
      let lhsIdentifier = fileResourceIdentifier(lhs),
      let rhsIdentifier = fileResourceIdentifier(rhs)
    else { return false }
    return lhsIdentifier.isEqual(rhsIdentifier)
  }
}
