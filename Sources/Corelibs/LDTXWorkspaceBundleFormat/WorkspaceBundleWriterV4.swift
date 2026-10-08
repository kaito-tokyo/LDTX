// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import SwiftProtobuf

public struct WorkspaceBundleWriterV4 {
  public let bundleURL: URL
  private var randomNumberGenerator: any RandomNumberGenerator

  public init?(
    at bundleURL: URL,
    randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator(),
    fileManager: FileManager = .default
  ) {
    let infoURL = bundleURL.appending(path: "Info.plist", directoryHint: .notDirectory)
    do {
      try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)
      if !fileManager.fileExists(atPath: infoURL.path) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(WorkspaceBundleInfoV4()).write(to: infoURL, options: .atomic)
      }
    } catch {
      return nil
    }
    self.bundleURL = bundleURL
    self.randomNumberGenerator = randomNumberGenerator
  }

  public var definitionURL: URL {
    bundleURL.appending(path: "definition.pb", directoryHint: .notDirectory)
  }

  public var preferencesURL: URL {
    bundleURL.appending(path: "preferences.pb", directoryHint: .notDirectory)
  }

  public func write(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    externalID: UUID
  ) throws -> UUID {
    try validateExternalID(externalID)
    var envelope = Ldtx_Envelope_WorkspaceDefinitionEnvelope()
    envelope.externalIDAsUUID = externalID
    envelope.workspaceDefinitionV4 = definition
    var options = BinaryEncodingOptions()
    options.useDeterministicOrdering = true
    let data = try envelope.serializedData(options: options)
    try data.write(to: definitionURL, options: .atomic)
    return externalID
  }

  public func write(
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4,
    externalID: UUID
  ) throws -> UUID {
    try validateExternalID(externalID)
    var envelope = Ldtx_Envelope_WorkspacePreferencesEnvelope()
    envelope.externalIDAsUUID = externalID
    envelope.workspacePreferencesV4 = preferences
    var options = BinaryEncodingOptions()
    options.useDeterministicOrdering = true
    let data = try envelope.serializedData(options: options)
    try data.write(to: preferencesURL, options: .atomic)
    return externalID
  }

  public var outputSettingsURL: URL {
    bundleURL.appending(path: "output_settings.pb", directoryHint: .notDirectory)
  }

  public func write(
    outputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4,
    externalID: UUID
  ) throws -> UUID {
    try validateExternalID(externalID)
    var envelope = Ldtx_Envelope_WorkspaceOutputSettingsEnvelope()
    envelope.externalIDAsUUID = externalID
    envelope.workspaceOutputSettingsV4 = outputSettings
    var options = BinaryEncodingOptions()
    options.useDeterministicOrdering = true
    try envelope.serializedData(options: options).write(to: outputSettingsURL, options: .atomic)
    return externalID
  }

  private func validateExternalID(_ identifier: UUID) throws {
    guard identifier.uuid.6 >> 4 == 7, identifier.uuid.8 & 0xc0 == 0x80 else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
  }

  public mutating func makeExternalID() -> UUID {
    Self.makeExternalID(using: &randomNumberGenerator)
  }

  /// Generates an envelope identifier without creating a package on disk.
  public static func makeExternalID() -> UUID {
    var generator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    return makeExternalID(using: &generator)
  }

  private static func makeExternalID(using randomNumberGenerator: inout any RandomNumberGenerator)
    -> UUID
  {
    let milliseconds = UInt64(Date().timeIntervalSince1970 * 1_000)
    let randomA = UInt16(truncatingIfNeeded: randomNumberGenerator.next())
    let randomB = randomNumberGenerator.next() & 0x3fff_ffff_ffff_ffff
    var bytes = [UInt8](repeating: 0, count: 16)
    for (index, shift) in stride(from: 40, through: 0, by: -8).enumerated() {
      bytes[index] = UInt8((milliseconds >> shift) & 0xff)
    }
    bytes[6] = 0x70 | UInt8((randomA >> 8) & 0x0f)
    bytes[7] = UInt8(randomA & 0xff)
    bytes[8] = 0x80 | UInt8((randomB >> 56) & 0x3f)
    for index in 0..<7 {
      bytes[index + 9] = UInt8((randomB >> (48 - index * 8)) & 0xff)
    }
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}
