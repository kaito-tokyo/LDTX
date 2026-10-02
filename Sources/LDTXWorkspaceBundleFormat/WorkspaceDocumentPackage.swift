// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import SwiftProtobuf

/// Serializes model files without materializing package resources in memory.
public enum WorkspaceDocumentPackage {
  public static func write(
    _ workspace: WorkspaceV4Bundle, to destination: URL, preserving sourceURL: URL? = nil,
    createsPackage: Bool = false
  ) throws {
    try WorkspaceV4IntegrityValidator.validate(workspace)
    var definition = Ldtx_Envelope_WorkspaceDefinitionEnvelope()
    definition.externalID =
      workspace.definitionExternalID
      ?? WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased()
    definition.workspaceDefinitionV4 = workspace.definition
    var preferences = Ldtx_Envelope_WorkspacePreferencesEnvelope()
    preferences.externalID =
      workspace.preferencesExternalID
      ?? WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased()
    preferences.workspacePreferencesV4 = workspace.preferences
    var options = BinaryEncodingOptions()
    options.useDeterministicOrdering = true
    let definitionData = try definition.serializedData(options: options)
    let preferencesData = try preferences.serializedData(options: options)
    let manager = FileManager.default
    if createsPackage {
      try manager.createDirectory(at: destination, withIntermediateDirectories: true)
      if let sourceURL, sourceURL.standardizedFileURL != destination.standardizedFileURL {
        for child in try manager.contentsOfDirectory(
          at: sourceURL, includingPropertiesForKeys: nil
        ) where !["definition.pb", "preferences.pb"].contains(child.lastPathComponent) {
          let target = destination.appendingPathComponent(child.lastPathComponent)
          // Recovery saves can reuse their destination; refresh its preserved contents.
          if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
          try manager.copyItem(at: child, to: target)
        }
      }
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
  }
}
