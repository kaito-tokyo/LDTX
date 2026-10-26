// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum WorkspaceModelFiles {
  static func isValidBaseName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
      && ["mlmodel", "mlpackage"].contains((name as NSString).pathExtension.lowercased())
  }

  public static func modelURL(
    for vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, in models: [Int64: URL]
  ) -> URL? {
    guard let id = vision.modelInternalID, id > 0 else { return nil }
    return models[id]
  }

  static func validateDirectory(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
      }
    }
  }

  static func validateModel(at url: URL) throws {
    #if os(macOS)
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    #endif
    guard url.isFileURL, isValidBaseName(url.lastPathComponent) else {
      throw CocoaError(.fileReadInvalidFileName, userInfo: [NSURLErrorKey: url])
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if url.pathExtension.lowercased() == "mlmodel" {
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
      }
      return
    }
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
    }
    let manifest = url.appendingPathComponent("Manifest.json")
    let manifestAttributes = try FileManager.default.attributesOfItem(atPath: manifest.path)
    guard manifestAttributes[.type] as? FileAttributeType == .typeRegular else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: manifest])
    }
    func validateContents(_ directory: URL) throws {
      for file in try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory: try validateContents(file)
        case .typeRegular: break
        default: throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: file])
        }
      }
    }
    try validateContents(url)
  }

  /// Resolves one model per ID, using the first supported basename in lexical order.
  public static func read(at bundleURL: URL) throws -> [Int64: URL] {
    let root = bundleURL.appendingPathComponent("VisionModels", isDirectory: true)
    try validateDirectory(root)
    guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
    var models: [Int64: URL] = [:]
    for directory in try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    {
      guard let id = Int64(directory.lastPathComponent), id > 0,
        directory.lastPathComponent == String(id)
      else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: directory]) }
      try validateDirectory(directory)
      let candidates = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      )
      .filter { isValidBaseName($0.lastPathComponent) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      if let selected = candidates.first {
        models[id] = selected
      }
    }
    return models
  }

  /// Copies resources without changing their IDs or replacing previously saved models.
  static func write(_ models: [Int64: URL], to bundleURL: URL) throws {
    guard !models.isEmpty else { return }
    let manager = FileManager.default
    let root = bundleURL.appendingPathComponent("VisionModels", isDirectory: true)
    try validateDirectory(root)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    for (id, source) in models.sorted(by: { $0.key < $1.key }) {
      let directory = root.appendingPathComponent(String(id), isDirectory: true)
      try validateDirectory(directory)
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      let target = directory.appendingPathComponent(source.lastPathComponent)
      if manager.fileExists(atPath: target.path) {
        try validateModel(at: target)
        continue
      }
      #if os(macOS)
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
      #endif
      let staged = directory.appendingPathComponent(UUID().uuidString)
      defer { try? manager.removeItem(at: staged) }
      try manager.copyItem(at: source, to: staged)
      try manager.moveItem(at: staged, to: target)
    }
  }
}
