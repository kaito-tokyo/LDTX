// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum WorkspaceResourceNameValidator {
  public static func validate(_ workspace: WorkspaceDefinition) throws {
    var seen = Set<String>()
    for name in workspaceResourceNames(in: workspace) {
      guard seen.insert(name).inserted else {
        throw WorkspaceResourceNameValidationError.duplicateName(name)
      }
    }
  }

  public static func isAvailable(
    _ name: String,
    inputDevices: [WorkspaceInputDeviceRecord],
    videoComponents: [WorkspaceVideoComponentRecord] = [],
    visions: [WorkspaceVisionDefinition],
    excludingResourceID: String? = nil
  ) -> Bool {
    !resourceNames(
      inputDevices: inputDevices,
      videoComponents: videoComponents,
      visions: visions,
      excludingResourceID: excludingResourceID
    ).contains(name)
  }

  public static func uniqueName(
    base: String,
    inputDevices: [WorkspaceInputDeviceRecord],
    videoComponents: [WorkspaceVideoComponentRecord] = [],
    visions: [WorkspaceVisionDefinition]
  ) -> String {
    let existing = resourceNames(
      inputDevices: inputDevices,
      videoComponents: videoComponents,
      visions: visions
    )
    guard existing.contains(base) else { return base }
    var suffix = 2
    while existing.contains("\(base) \(suffix)") { suffix += 1 }
    return "\(base) \(suffix)"
  }

  public static func nextNumberedName(
    label: String,
    inputDevices: [WorkspaceInputDeviceRecord],
    videoComponents: [WorkspaceVideoComponentRecord] = [],
    visions: [WorkspaceVisionDefinition]
  ) -> String {
    let names = resourceNames(
      inputDevices: inputDevices,
      videoComponents: videoComponents,
      visions: visions
    )
    let nextNumber = names.compactMap(numberedNamePrefix).max().map { $0 + 1 } ?? 1
    return "\(nextNumber)-\(label.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  private static func numberedNamePrefix(_ name: String) -> Int? {
    guard let separator = name.firstIndex(of: "-") else { return nil }
    return Int(name[..<separator])
  }

  private static func workspaceResourceNames(in workspace: WorkspaceDefinition) -> [String] {
    workspace.inputDevices.map(\.name) + workspace.videoComponents.map(\.name)
      + workspace.visions.map(\.name)
  }

  private static func resourceNames(
    inputDevices: [WorkspaceInputDeviceRecord],
    videoComponents: [WorkspaceVideoComponentRecord],
    visions: [WorkspaceVisionDefinition],
    excludingResourceID: String? = nil
  ) -> Set<String> {
    Set(
      inputDevices.filter { $0.id != excludingResourceID }.map(\.name)
        + videoComponents.filter { $0.id != excludingResourceID }.map(\.name)
        + visions.filter { $0.id != excludingResourceID }.map(\.name)
    )
  }
}

public enum WorkspaceResourceNameValidationError: LocalizedError, Equatable, Sendable {
  case duplicateName(String)

  public var errorDescription: String? {
    switch self {
    case .duplicateName(let name):
      "Workspace resource name \"\(name)\" is used more than once. Input Devices, Video Components, and Visions must have unique names."
    }
  }
}
