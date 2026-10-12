// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos

public enum WorkspaceModelFiles {
  /// Reads a model, preserving its basename. Package data encodes its relative files as JSON.
  public static func importModel(at url: URL) throws -> (name: String, data: Data) {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let name = url.lastPathComponent
    guard isValidBaseName(name) else { throw CocoaError(.fileReadInvalidFileName) }
    if url.pathExtension.lowercased() == "mlpackage" {
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
      }
      let files = try readPackage(at: url)
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      return (name, try encoder.encode(files))
    }
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
    }
    return (name, try Data(contentsOf: url))
  }

  /// Prepares external selections for a Document save without changing live state.
  public static func preparedForSaving(
    _ workspace: WorkspaceV4Bundle, modelURLs: [Int64: URL?] = [:]
  ) throws -> WorkspaceV4Bundle {
    var saved = workspace
    for index in saved.definition.visions.indices {
      guard
        case .ldtxSceneDetectorVision(var vision) = saved.definition.visions[index].vision,
        let selected = modelURLs[vision.internalID]
      else { continue }
      if let url = selected {
        #if os(macOS)
          let accessed = url.startAccessingSecurityScopedResource()
          defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        #endif
        let imported = try importModel(at: url)
        var revision: Int64
        repeat {
          let milliseconds = Int64(max(0, Date().timeIntervalSince1970 * 1_000))
          revision = ((milliseconds & 0x0000_FFFF_FFFF_FFFF) << 15)
            | (Int64.random(in: 0...0x3fff) << 1) | 1
        } while saved.models.keys.contains(where: { $0.hasPrefix("\(vision.internalID)/\(revision)/") })
        vision.modelRevision = revision
        saved.models["\(vision.internalID)/\(revision)/\(imported.name)"] = imported.data
      } else {
        vision.modelRevision = 0
      }
      saved.definition.visions[index].vision = .ldtxSceneDetectorVision(vision)
    }
    try validate(saved)
    return saved
  }

  static func isValidBaseName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
      && ["mlmodel", "mlpackage"].contains((name as NSString).pathExtension.lowercased())
  }

  static func isValidName(_ name: String) -> Bool {
    let parts = name.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 3 && (Int64(parts[0]) ?? 0) > 0
      && (Int64(parts[1]) ?? 0) > 0 && isValidBaseName(String(parts[2]))
  }

  /// Selects the lexicographically first model in the assigned revision.
  public static func modelPath(
    for vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, in models: [String: Data]
  ) -> String? {
    guard vision.modelRevision > 0 else { return nil }
    let prefix = "\(vision.internalID)/\(vision.modelRevision)/"
    return models.keys.filter { $0.hasPrefix(prefix) && isValidName($0) }.sorted().first
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
    for (name, data) in workspace.models where (name as NSString).pathExtension.lowercased() == "mlpackage" {
      _ = try packageFiles(from: data)
    }
    for wrapper in workspace.definition.visions {
      guard case .ldtxSceneDetectorVision(let vision) = wrapper.vision,
        vision.modelRevision != 0
      else { continue }
      guard modelPath(for: vision, in: workspace.models) != nil
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
      for revisionDirectory in try FileManager.default.contentsOfDirectory(
        at: modelDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
      {
        guard (Int64(revisionDirectory.lastPathComponent) ?? 0) > 0 else {
          throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: revisionDirectory])
        }
        try validateDirectory(revisionDirectory)
        for url in try FileManager.default.contentsOfDirectory(
          at: revisionDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        {
          guard isValidBaseName(url.lastPathComponent) else { continue }
          let name = modelDirectory.lastPathComponent + "/" + revisionDirectory.lastPathComponent
            + "/" + url.lastPathComponent
          models[name] = try importModel(at: url).data
        }
      }
    }
    return models
  }

  // Package resources are encoded only in memory; the bundle stores the native directory.
  private static func readPackage(at root: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    func visit(_ directory: URL, prefix: String) throws {
      for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        let name = prefix + url.lastPathComponent
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory: try visit(url, prefix: name + "/")
        case .typeRegular: files[name] = try Data(contentsOf: url)
        default: throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
      }
    }
    try visit(root, prefix: "")
    try validatePackageFiles(files)
    return files
  }

  private static func validatePackageFiles(_ files: [String: Data]) throws {
    guard files["Manifest.json"] != nil,
      files.keys.allSatisfy({ name in
        name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
          !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0")
        }
      })
    else { throw CocoaError(.fileReadCorruptFile) }
  }

  private static func packageFiles(from data: Data) throws -> [String: Data] {
    let files = try JSONDecoder().decode([String: Data].self, from: data)
    try validatePackageFiles(files)
    return files
  }

  static func writeModel(_ data: Data, to url: URL) throws {
    guard url.pathExtension.lowercased() == "mlpackage" else {
      try data.write(to: url, options: .atomic)
      return
    }
    let files = try packageFiles(from: data)
    let manager = FileManager.default
    let parent = url.deletingLastPathComponent()
    let staged = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let backup = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? manager.removeItem(at: staged) }
    try manager.createDirectory(at: staged, withIntermediateDirectories: false)
    for (name, contents) in files {
      let file = staged.appendingPathComponent(name)
      try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: file)
    }
    let existed = manager.fileExists(atPath: url.path)
    if existed {
      try validateDirectory(url)
      try manager.moveItem(at: url, to: backup)
    }
    do { try manager.moveItem(at: staged, to: url) }
    catch {
      if existed { try manager.moveItem(at: backup, to: url) }
      throw error
    }
    if existed { try? manager.removeItem(at: backup) }
  }
}
