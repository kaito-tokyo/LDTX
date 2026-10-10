// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos

public enum WorkspaceModelFiles {
  /// Reads a standalone model, preserving its basename.
  public static func importModel(at url: URL) throws -> (name: String, data: Data) {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard url.pathExtension.lowercased() == "mlmodel",
      attributes[.type] as? FileAttributeType == .typeRegular
    else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
    let name = url.lastPathComponent
    guard isValidBaseName(name) else { throw CocoaError(.fileReadInvalidFileName) }
    return (name, try Data(contentsOf: url))
  }

  /// Prepares external selections for a Document save without changing live state.
  public static func preparedForSaving(
    _ workspace: WorkspaceV4Bundle, modelURLs: [Int64: URL?] = [:]
  ) throws -> WorkspaceV4Bundle {
    var saved = workspace
    for index in saved.definition.visions.indices {
      guard
        case .createMlImageClassifierVision(var vision) = saved.definition.visions[index].vision,
        let selected = modelURLs[vision.internalID]
      else { continue }
      if let url = selected {
        #if os(macOS)
          let accessed = url.startAccessingSecurityScopedResource()
          defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        #endif
        let imported = try importModel(at: url)
        vision.modelFileName = imported.name
        saved.models["\(vision.internalID)/\(imported.name)"] = imported.data
      } else {
        vision.modelFileName = ""
      }
      saved.definition.visions[index].vision = .createMlImageClassifierVision(vision)
    }
    try validate(saved)
    return saved
  }

  static func isValidBaseName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
      && (name as NSString).pathExtension.lowercased() == "mlmodel"
  }

  static func isValidName(_ name: String) -> Bool {
    let parts = name.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2 && (Int64(parts[0]) ?? 0) > 0
      && isValidBaseName(String(parts[1]))
  }

  static func validateDirectory(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
      }
    }
  }

  static func validate(_ workspace: WorkspaceV4Bundle) throws {
    guard workspace.models.keys.allSatisfy(isValidName) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    for wrapper in workspace.definition.visions {
      guard case .createMlImageClassifierVision(let vision) = wrapper.vision,
        !vision.modelFileName.isEmpty
      else { continue }
      guard isValidBaseName(vision.modelFileName),
        workspace.models["\(vision.internalID)/\(vision.modelFileName)"] != nil
      else {
        throw CocoaError(.fileReadCorruptFile)
      }
    }
  }

  static func read(at bundleURL: URL) throws -> [String: Data] {
    let directory = bundleURL.appendingPathComponent("VisionModels", isDirectory: true)
    try validateDirectory(directory)
    guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
    var models: [String: Data] = [:]
    for modelDirectory in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      guard (Int64(modelDirectory.lastPathComponent) ?? 0) > 0 else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: modelDirectory])
      }
      try validateDirectory(modelDirectory)
      for url in try FileManager.default.contentsOfDirectory(
        at: modelDirectory, includingPropertiesForKeys: nil)
      {
        let name = modelDirectory.lastPathComponent + "/" + url.lastPathComponent
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, isValidName(name) else {
          throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        models[name] = try Data(contentsOf: url)
      }
    }
    return models
  }
}
