// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import SwiftProtobuf

/// Serializes model files without materializing package resources in memory.
public enum WorkspaceDocumentPackage {
  public static func write(
    _ workspace: WorkspaceV4Bundle, to destination: URL,
    createsPackage: Bool = false
  ) throws {
    try WorkspaceV4IntegrityValidator.validate(workspace)
    var definition = Ldtx_Envelope_WorkspaceDefinitionEnvelope()
    definition.externalIDAsUUID = try envelopeIdentifier(workspace.definitionExternalID)
    definition.workspaceDefinitionV4 = workspace.definition
    var preferences = Ldtx_Envelope_WorkspacePreferencesEnvelope()
    preferences.externalIDAsUUID = try envelopeIdentifier(workspace.preferencesExternalID)
    preferences.workspacePreferencesV4 = workspace.preferences
    var outputSettings = Ldtx_Envelope_WorkspaceOutputSettingsEnvelope()
    outputSettings.externalIDAsUUID = try envelopeIdentifier(workspace.outputSettingsExternalID)
    outputSettings.workspaceOutputSettingsV4 = workspace.outputSettings
    var options = BinaryEncodingOptions()
    options.useDeterministicOrdering = true
    let definitionData = try definition.serializedData(options: options)
    let preferencesData = try preferences.serializedData(options: options)
    let outputSettingsData = try outputSettings.serializedData(options: options)
    let manager = FileManager.default
    if createsPackage {
      try manager.createDirectory(at: destination, withIntermediateDirectories: true)
      let infoURL = destination.appendingPathComponent("Info.plist")
      if !manager.fileExists(atPath: infoURL.path) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(WorkspaceBundleInfoV4()).write(to: infoURL, options: .atomic)
      }
    }
    try definitionData.write(
      to: destination.appendingPathComponent("definition.pb"), options: .atomic)
    try preferencesData.write(
      to: destination.appendingPathComponent("preferences.pb"), options: .atomic)
    try outputSettingsData.write(
      to: destination.appendingPathComponent("output_settings.pb"), options: .atomic)
  }

  private static func envelopeIdentifier(_ identifier: String?) throws -> UUID {
    guard let identifier else {
      return WorkspaceBundleWriterV4.makeExternalID()
    }
    guard let uuid = UUID(uuidString: identifier),
      uuid.uuid.6 >> 4 == 7, uuid.uuid.8 & 0xc0 == 0x80
    else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    return uuid
  }

}
