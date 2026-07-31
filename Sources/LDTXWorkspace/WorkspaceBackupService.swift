// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct WorkspaceBackupGeneration: Equatable, Sendable {
  public var packageURL: URL
  public var rollbackPackageURL: URL?

  public init(packageURL: URL, rollbackPackageURL: URL?) {
    self.packageURL = packageURL
    self.rollbackPackageURL = rollbackPackageURL
  }
}

public struct WorkspaceBackupGenerationMetadata: Codable, Equatable, Sendable {
  public var lineageID: UUID
  public var savedAt: Date
  public var sourcePath: String

  public init(lineageID: UUID, savedAt: Date, sourcePath: String) {
    self.lineageID = lineageID
    self.savedAt = savedAt
    self.sourcePath = sourcePath
  }
}

public struct WorkspaceBackupService {
  public static let defaultMaximumGenerationCount = 10

  private let fileManager: FileManager
  private let rootDirectoryURL: URL?
  private let maximumGenerationCount: Int
  private let now: () -> Date

  public init(
    fileManager: FileManager = .default,
    rootDirectoryURL: URL? = nil,
    maximumGenerationCount: Int = defaultMaximumGenerationCount,
    now: @escaping () -> Date = Date.init
  ) {
    precondition(maximumGenerationCount > 0)
    self.fileManager = fileManager
    self.rootDirectoryURL = rootDirectoryURL
    self.maximumGenerationCount = maximumGenerationCount
    self.now = now
  }

  public func createGeneration(
    lineageID: UUID,
    sourcePackageURL: URL,
    populate: (URL) throws -> Void
  ) throws -> WorkspaceBackupGeneration {
    let savedAt = now()
    let lineageDirectoryURL = try lineageDirectory(for: lineageID)
    try fileManager.createDirectory(
      at: lineageDirectoryURL,
      withIntermediateDirectories: true
    )

    let generationDirectoryURL = lineageDirectoryURL.appendingPathComponent(
      "\(Self.generationTimestamp(from: savedAt))-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    let packageURL = generationDirectoryURL.appendingPathComponent(
      "Workspace.ldtxworkspace",
      isDirectory: true
    )
    let rollbackPackageURL = generationDirectoryURL.appendingPathComponent(
      "Rollback.ldtxworkspace",
      isDirectory: true
    )
    try fileManager.createDirectory(at: generationDirectoryURL, withIntermediateDirectories: false)
    do {
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: sourcePackageURL.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        try fileManager.copyItem(at: sourcePackageURL, to: packageURL)
        try fileManager.copyItem(at: sourcePackageURL, to: rollbackPackageURL)
      } else {
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: false)
      }
      try populate(packageURL)

      let metadata = WorkspaceBackupGenerationMetadata(
        lineageID: lineageID,
        savedAt: savedAt,
        sourcePath: sourcePackageURL.standardizedFileURL.path
      )
      let metadataData = try JSONEncoder.workspaceBackupEncoder.encode(metadata)
      try metadataData.write(
        to: generationDirectoryURL.appendingPathComponent("metadata.json"),
        options: [.atomic]
      )
      try fileManager.setAttributes(
        [.modificationDate: savedAt],
        ofItemAtPath: generationDirectoryURL.path
      )
      return WorkspaceBackupGeneration(
        packageURL: packageURL,
        rollbackPackageURL: isDirectory.boolValue ? rollbackPackageURL : nil
      )
    } catch {
      try? fileManager.removeItem(at: generationDirectoryURL)
      throw error
    }
  }

  public func finishGeneration(_ generation: WorkspaceBackupGeneration) throws {
    if let rollbackPackageURL = generation.rollbackPackageURL,
      fileManager.fileExists(atPath: rollbackPackageURL.path)
    {
      try fileManager.removeItem(at: rollbackPackageURL)
    }
    try pruneGenerations(
      in: generation.packageURL.deletingLastPathComponent().deletingLastPathComponent()
    )
  }

  public func discardGeneration(_ generation: WorkspaceBackupGeneration) throws {
    let generationDirectoryURL = generation.packageURL.deletingLastPathComponent()
    guard fileManager.fileExists(atPath: generationDirectoryURL.path) else { return }
    try fileManager.removeItem(at: generationDirectoryURL)
  }

  public func generationPackageURLs(for lineageID: UUID) throws -> [URL] {
    let lineageDirectoryURL = try lineageDirectory(for: lineageID)
    guard fileManager.fileExists(atPath: lineageDirectoryURL.path) else { return [] }
    return try generationDirectories(in: lineageDirectoryURL).map {
      $0.appendingPathComponent("Workspace.ldtxworkspace", isDirectory: true)
    }
  }

  private func lineageDirectory(for lineageID: UUID) throws -> URL {
    let rootDirectoryURL = try rootDirectoryURL ?? defaultRootDirectory()
    return rootDirectoryURL.appendingPathComponent(
      lineageID.uuidString.lowercased(),
      isDirectory: true
    )
  }

  private func defaultRootDirectory() throws -> URL {
    try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    .appendingPathComponent("LDTX", isDirectory: true)
    .appendingPathComponent("WorkspaceBackups", isDirectory: true)
  }

  private func pruneGenerations(in lineageDirectoryURL: URL) throws {
    let generations = try generationDirectories(in: lineageDirectoryURL)
    for generationURL in generations.dropFirst(maximumGenerationCount) {
      try fileManager.removeItem(at: generationURL)
    }
  }

  private func generationDirectories(in lineageDirectoryURL: URL) throws -> [URL] {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
    return try fileManager.contentsOfDirectory(
      at: lineageDirectoryURL,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    )
    .filter { try $0.resourceValues(forKeys: keys).isDirectory == true }
    .sorted {
      let lhs = try $0.resourceValues(forKeys: keys).contentModificationDate ?? .distantPast
      let rhs = try $1.resourceValues(forKeys: keys).contentModificationDate ?? .distantPast
      return lhs > rhs
    }
  }

  private static func generationTimestamp(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

extension JSONEncoder {
  fileprivate static var workspaceBackupEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
