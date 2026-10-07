// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import SwiftProtobuf

/// Reads and inspects protobuf-only Version 4 Workspace bundles.
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

    let definitionEnvelope = try Ldtx_Envelope_WorkspaceDefinitionEnvelope(
      serializedBytes: try Data(contentsOf: definitionURL))
    let preferencesEnvelope = try Ldtx_Envelope_WorkspacePreferencesEnvelope(
      serializedBytes: try Data(contentsOf: preferencesURL))
    guard
      let definitionExternalID = definitionEnvelope.externalIDAsUUID,
      let preferencesExternalID = preferencesEnvelope.externalIDAsUUID
    else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: bundleURL])
    }

    return WorkspaceV4Bundle(
      definitionExternalID: definitionExternalID.uuidString.lowercased(),
      preferencesExternalID: preferencesExternalID.uuidString.lowercased(),
      definition: definitionEnvelope.workspaceDefinitionV4,
      preferences: preferencesEnvelope.workspacePreferencesV4)
  }
}
