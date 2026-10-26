// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Reads Version 4 Workspace documents and imported model resources.
public struct WorkspaceBundleReaderV4 {
  public let bundleURL: URL

  public init(at bundleURL: URL) {
    self.bundleURL = bundleURL
  }

  var definitionURL: URL {
    bundleURL.appending(path: "definition.pb", directoryHint: .notDirectory)
  }

  var preferencesURL: URL {
    bundleURL.appending(path: "preferences.pb", directoryHint: .notDirectory)
  }

  public func read() throws -> WorkspaceV4Bundle {
    _ = try WorkspaceBundleValidatorV4(at: bundleURL).validate()

    let legacyDefinitionURL = bundleURL.appending(
      path: "workspace.json", directoryHint: .notDirectory)
    let legacyPreferencesURL = bundleURL.appending(
      path: "preferences.json", directoryHint: .notDirectory)
    guard
      !FileManager.default.fileExists(atPath: legacyDefinitionURL.path),
      !FileManager.default.fileExists(atPath: legacyPreferencesURL.path)
    else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: bundleURL])
    }

    var definitionEnvelope = try Ldtx_Envelope_WorkspaceDefinitionEnvelope(
      serializedBytes: try Data(contentsOf: definitionURL))
    let preferencesEnvelope = try Ldtx_Envelope_WorkspacePreferencesEnvelope(
      serializedBytes: try Data(contentsOf: preferencesURL))
    let outputSettingsEnvelope = try Ldtx_Envelope_WorkspaceOutputSettingsEnvelope(
      serializedBytes: try Data(contentsOf: bundleURL.appending(path: "output_settings.pb")))
    guard
      case .workspaceDefinitionV4(let definition) = definitionEnvelope.workspaceDefinition,
      case .workspacePreferencesV4(let preferences) = preferencesEnvelope.workspacePreferences,
      case .workspaceOutputSettingsV4(let outputSettings) = outputSettingsEnvelope
        .workspaceOutputSettings,
      let outputSettingsExternalID = outputSettingsEnvelope.externalIDAsUUID,
      let definitionExternalID = definitionEnvelope.externalIDAsUUID,
      isUUIDv7(definitionExternalID),
      let preferencesExternalID = preferencesEnvelope.externalIDAsUUID,
      isUUIDv7(preferencesExternalID), isUUIDv7(outputSettingsExternalID)
    else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: bundleURL])
    }

    let workspace = WorkspaceV4Bundle(
      definitionExternalID: definitionExternalID.uuidString.lowercased(),
      preferencesExternalID: preferencesExternalID.uuidString.lowercased(),
      definition: definition,
      preferences: preferences,
      outputSettingsExternalID: outputSettingsExternalID.uuidString.lowercased(),
      outputSettings: outputSettings,
      visionModels: try WorkspaceModelFiles.read(at: bundleURL))
    try WorkspaceBundleValidatorV4.validate(workspace)
    return workspace
  }
  private func isUUIDv7(_ value: UUID) -> Bool {
    value.uuid.6 >> 4 == 7 && value.uuid.8 & 0xc0 == 0x80
  }

}
