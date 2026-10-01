// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import SwiftProtobuf

/// Builds a complete package snapshot for NSDocument's safe-saving machinery.
public enum WorkspaceDocumentPackage {
  public static func fileWrapper(
    for workspace: WorkspaceV4Bundle, preserving sourceURL: URL?
  ) throws -> FileWrapper {
    try WorkspaceV4IntegrityValidator.validate(workspace)
    let wrapper: FileWrapper
    if let sourceURL {
      wrapper = try FileWrapper(url: sourceURL, options: .immediate)
      guard wrapper.isDirectory else { throw CocoaError(.fileReadCorruptFile) }
    } else {
      wrapper = FileWrapper(directoryWithFileWrappers: [:])
    }
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
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    let contents = [
      "Info.plist": try encoder.encode(WorkspaceBundleInfoV4()),
      "definition.pb": try definition.serializedData(options: options),
      "preferences.pb": try preferences.serializedData(options: options),
    ]
    for (name, data) in contents {
      if name == "Info.plist", wrapper.fileWrappers?[name] != nil { continue }
      if let existing = wrapper.fileWrappers?[name] { wrapper.removeFileWrapper(existing) }
      wrapper.addRegularFile(withContents: data, preferredFilename: name)
    }
    return wrapper
  }
}
