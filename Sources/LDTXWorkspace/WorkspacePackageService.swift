// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum WorkspacePackageLayout {
  public static let pathExtension = "ldtxworkspace"
  public static let protobufFileName = "workspace.pb"
  public static let jsonFileName = "workspace.json"
  public static let preferencesProtobufFileName = "preferences.pb"
  public static let preferencesJSONFileName = "preferences.json"
  public static let assetsDirectoryName = "Assets"
  public static let extensionsDirectoryName = "Extensions"
}

public struct WorkspacePackageService {
  private let fileManager: FileManager
  private let backupService: WorkspaceBackupService?
  private let writeData: (Data, URL) throws -> Void
  private let publishData: (Data, URL) throws -> Void

  public init(
    fileManager: FileManager = .default,
    backupService: WorkspaceBackupService? = nil,
    writeData: @escaping (Data, URL) throws -> Void = { data, url in
      try data.write(to: url, options: [.atomic])
    },
    publishData: @escaping (Data, URL) throws -> Void = { data, url in
      try data.write(to: url, options: [.atomic])
    }
  ) {
    self.fileManager = fileManager
    self.backupService = backupService
    self.writeData = writeData
    self.publishData = publishData
  }

  public func loadWorkspace(at packageURL: URL) throws -> WorkspaceSnapshot {
    try loadWorkspaceContents(at: packageURL).snapshot
  }

  public func loadWorkspacePersistence(
    at packageURL: URL
  ) throws -> (snapshot: WorkspaceSnapshot, persistedWorkspaceData: Data) {
    try loadWorkspaceContents(at: packageURL)
  }

  @MainActor
  public func loadWorkspaceStore(at packageURL: URL) throws -> WorkspaceStore {
    let loaded = try loadWorkspacePersistence(at: packageURL)
    return WorkspaceStore(
      snapshot: loaded.snapshot,
      lastSavedBytes: loaded.persistedWorkspaceData
    )
  }

  private func loadWorkspaceContents(
    at packageURL: URL
  ) throws -> (snapshot: WorkspaceSnapshot, persistedWorkspaceData: Data) {
    let package = try packageDirectory(at: packageURL)
    let data = try Data(
      contentsOf: package.appendingPathComponent(WorkspacePackageLayout.protobufFileName))
    let preferencesURL = package.appendingPathComponent(
      WorkspacePackageLayout.preferencesProtobufFileName)
    let preferences = try WorkspacePersistenceCodec.decodePreferences(
      from: Data(contentsOf: preferencesURL)
    )
    let snapshot = try WorkspacePersistenceCodec.decodeWorkspace(
      from: data,
      preferences: preferences
    )
    return (snapshot: snapshot, persistedWorkspaceData: data)
  }

  @MainActor
  public func saveWorkspaceStore(_ store: WorkspaceStore, to packageURL: URL) throws {
    let snapshot = try store.persistenceSnapshot()
    try save(snapshot, to: packageURL)
    store.markSaved(snapshot)
  }

  public func save(_ snapshot: WorkspacePersistenceSnapshot, to packageURL: URL) throws {
    let protobufData = snapshot.protobufData
    let jsonData = try WorkspacePersistenceCodec.encodeWorkspaceJSON(snapshot.definition)
    let preferencesProtobufData = try WorkspacePersistenceCodec.encodePreferences(
      snapshot.preferences)
    let preferencesJSONData = try WorkspacePersistenceCodec.encodePreferencesJSON(
      snapshot.preferences)

    if let backupService {
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      {
        throw WorkspacePackageServiceError.packageURLIsNotDirectory(packageURL)
      }
      let generation = try backupService.createGeneration(
        lineageID: snapshot.definition.lineageID,
        sourcePackageURL: packageURL
      ) { generationPackageURL in
        try updatePackageContents(
          at: generationPackageURL,
          workspaceProtobufData: protobufData,
          workspaceJSONData: jsonData,
          preferencesProtobufData: preferencesProtobufData,
          preferencesJSONData: preferencesJSONData
        )
      }
      do {
        _ = try loadWorkspace(at: generation.packageURL)
      } catch {
        try? backupService.discardGeneration(generation)
        throw error
      }
      do {
        try publishPackageContents(
          from: generation.packageURL,
          rollbackPackageURL: generation.rollbackPackageURL,
          to: packageURL
        )
        try? backupService.finishGeneration(generation)
      } catch let error as WorkspacePackageServiceError {
        if case .rollbackFailed = error {
          throw error
        }
        try? backupService.finishGeneration(generation)
        throw error
      } catch {
        try? backupService.finishGeneration(generation)
        throw error
      }
    } else {
      try replacePackage(
        at: packageURL,
        workspaceProtobufData: protobufData,
        workspaceJSONData: jsonData,
        preferencesProtobufData: preferencesProtobufData,
        preferencesJSONData: preferencesJSONData
      )
    }
  }

  /// Compiles both v3 JSON mirrors into their canonical protobuf files.
  /// The visible package is replaced only after both documents decode and the
  /// combined snapshot passes Workspace integrity validation.
  public func compileJSONMirrors(at packageURL: URL) throws {
    let package = try packageDirectory(at: packageURL)
    let preferences = try WorkspacePersistenceCodec.decodePreferencesJSON(
      from: Data(
        contentsOf: package.appendingPathComponent(
          WorkspacePackageLayout.preferencesJSONFileName)))
    let snapshot = try WorkspacePersistenceCodec.decodeWorkspaceJSON(
      from: Data(contentsOf: package.appendingPathComponent(WorkspacePackageLayout.jsonFileName)),
      preferences: preferences
    )
    let workspaceProtobufData = try WorkspacePersistenceCodec.encodeWorkspace(snapshot.definition)
    let preferencesProtobufData = try WorkspacePersistenceCodec.encodePreferences(
      snapshot.preferences)
    // Regenerate mirrors from the validated snapshot so protobuf and JSON are
    // guaranteed to describe the same semantic state.
    try replacePackage(
      at: package,
      workspaceProtobufData: workspaceProtobufData,
      workspaceJSONData: try WorkspacePersistenceCodec.encodeWorkspaceJSON(snapshot.definition),
      preferencesProtobufData: preferencesProtobufData,
      preferencesJSONData: try WorkspacePersistenceCodec.encodePreferencesJSON(
        snapshot.preferences)
    )
  }

  /// Validates the canonical protobuf pair and requires both JSON mirrors to
  /// decode to byte-for-byte equivalent deterministic protobuf messages.
  public func validatePackage(at packageURL: URL) throws {
    let package = try packageDirectory(at: packageURL)
    _ = try loadWorkspace(at: package)
    let canonicalWorkspaceData = try Data(
      contentsOf: package.appendingPathComponent(WorkspacePackageLayout.protobufFileName))
    let canonicalPreferencesData = try Data(
      contentsOf: package.appendingPathComponent(
        WorkspacePackageLayout.preferencesProtobufFileName))
    let mirrorWorkspaceData = try Data(
      contentsOf: package.appendingPathComponent(WorkspacePackageLayout.jsonFileName))
    let mirrorPreferencesData = try Data(
      contentsOf: package.appendingPathComponent(
        WorkspacePackageLayout.preferencesJSONFileName))
    let mirrorPreferences = try WorkspacePersistenceCodec.decodePreferencesJSON(
      from: mirrorPreferencesData)
    _ = try WorkspacePersistenceCodec.decodeWorkspaceJSON(
      from: mirrorWorkspaceData,
      preferences: mirrorPreferences
    )
    guard
      try WorkspacePersistenceCodec.normalizeWorkspaceProtobuf(canonicalWorkspaceData)
        == WorkspacePersistenceCodec.normalizeWorkspaceJSONProtobuf(mirrorWorkspaceData)
    else {
      throw WorkspacePackageServiceError.jsonMirrorMismatch(
        WorkspacePackageLayout.jsonFileName)
    }
    guard
      try WorkspacePersistenceCodec.normalizePreferencesProtobuf(canonicalPreferencesData)
        == WorkspacePersistenceCodec.normalizePreferencesJSONProtobuf(mirrorPreferencesData)
    else {
      throw WorkspacePackageServiceError.jsonMirrorMismatch(
        WorkspacePackageLayout.preferencesJSONFileName)
    }
  }

  /// Regenerates JSON mirrors from the canonical protobuf pair without using
  /// existing JSON as an input or fallback.
  public func emitJSONMirrors(at packageURL: URL) throws {
    let package = try packageDirectory(at: packageURL)
    let workspaceProtobufData = try Data(
      contentsOf: package.appendingPathComponent(WorkspacePackageLayout.protobufFileName))
    let preferencesProtobufData = try Data(
      contentsOf: package.appendingPathComponent(
        WorkspacePackageLayout.preferencesProtobufFileName))
    let preferences = try WorkspacePersistenceCodec.decodePreferences(
      from: preferencesProtobufData)
    let snapshot = try WorkspacePersistenceCodec.decodeWorkspace(
      from: workspaceProtobufData,
      preferences: preferences
    )
    try replacePackage(
      at: package,
      workspaceProtobufData: workspaceProtobufData,
      workspaceJSONData: try WorkspacePersistenceCodec.encodeWorkspaceJSON(snapshot.definition),
      preferencesProtobufData: preferencesProtobufData,
      preferencesJSONData: try WorkspacePersistenceCodec.encodePreferencesJSON(
        snapshot.preferences)
    )
  }

  private func updatePackageContents(
    at packageURL: URL,
    workspaceProtobufData: Data,
    workspaceJSONData: Data,
    preferencesProtobufData: Data,
    preferencesJSONData: Data
  ) throws {
    try removeObsoletePackageArtifacts(at: packageURL)
    try writeData(
      workspaceProtobufData,
      packageURL.appendingPathComponent(WorkspacePackageLayout.protobufFileName)
    )
    try writeData(
      workspaceJSONData,
      packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName)
    )
    try writeData(
      preferencesProtobufData,
      packageURL.appendingPathComponent(WorkspacePackageLayout.preferencesProtobufFileName)
    )
    try writeData(
      preferencesJSONData,
      packageURL.appendingPathComponent(WorkspacePackageLayout.preferencesJSONFileName)
    )
  }

  private func replacePackage(
    at packageURL: URL,
    workspaceProtobufData: Data,
    workspaceJSONData: Data,
    preferencesProtobufData: Data,
    preferencesJSONData: Data
  ) throws {
    let parentURL = packageURL.deletingLastPathComponent()
    let stagingURL = parentURL.appendingPathComponent(
      ".\(packageURL.lastPathComponent).staging-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: stagingURL) }

    var isDirectory: ObjCBool = false
    let packageExists = fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory)
    if packageExists {
      guard isDirectory.boolValue else {
        throw WorkspacePackageServiceError.packageURLIsNotDirectory(packageURL)
      }
      try fileManager.copyItem(at: packageURL, to: stagingURL)
      try removeObsoletePackageArtifacts(at: stagingURL)
    } else {
      try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    }

    try writeData(
      workspaceProtobufData,
      stagingURL.appendingPathComponent(WorkspacePackageLayout.protobufFileName)
    )
    try writeData(
      workspaceJSONData,
      stagingURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName)
    )
    try writeData(
      preferencesProtobufData,
      stagingURL.appendingPathComponent(WorkspacePackageLayout.preferencesProtobufFileName)
    )
    try writeData(
      preferencesJSONData,
      stagingURL.appendingPathComponent(WorkspacePackageLayout.preferencesJSONFileName)
    )

    // A dot-prefixed staging directory can acquire the hidden file flag on
    // macOS. Clear it before the directory becomes the visible package so
    // saving does not make the Workspace disappear from Finder.
    var visibleStagingURL = stagingURL
    var resourceValues = URLResourceValues()
    resourceValues.isHidden = false
    try visibleStagingURL.setResourceValues(resourceValues)

    if packageExists {
      _ = try fileManager.replaceItemAt(
        packageURL,
        withItemAt: stagingURL,
        backupItemName: nil,
        options: [.usingNewMetadataOnly]
      )
    } else {
      try fileManager.moveItem(at: stagingURL, to: packageURL)
    }
  }

  private func removeObsoletePackageArtifacts(at packageURL: URL) throws {
    let legacyLockURL = packageURL.appendingPathComponent("LDTX.lock")
    if fileManager.fileExists(atPath: legacyLockURL.path) {
      try fileManager.removeItem(at: legacyLockURL)
    }
  }

  private func publishPackageContents(
    from sourceURL: URL,
    rollbackPackageURL: URL?,
    to destinationURL: URL
  ) throws {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var accessorError: Error?
    let destinationExists = fileManager.fileExists(atPath: destinationURL.path)
    let coordinationURL =
      destinationExists
      ? destinationURL
      : destinationURL.deletingLastPathComponent()
    coordinator.coordinate(
      writingItemAt: coordinationURL,
      options: .forMerging,
      error: &coordinationError
    ) { coordinatedURL in
      let coordinatedDestinationURL =
        destinationExists
        ? coordinatedURL
        : coordinatedURL.appendingPathComponent(
          destinationURL.lastPathComponent,
          isDirectory: true
        )
      do {
        try synchronizeDirectoryContents(
          from: sourceURL,
          to: coordinatedDestinationURL
        )
        var visibleDestinationURL = coordinatedDestinationURL
        var resourceValues = URLResourceValues()
        resourceValues.isHidden = false
        try visibleDestinationURL.setResourceValues(resourceValues)
      } catch {
        let publicationError = error
        do {
          if let rollbackPackageURL {
            try synchronizeDirectoryContents(
              from: rollbackPackageURL,
              to: coordinatedDestinationURL
            )
          } else if fileManager.fileExists(atPath: coordinatedDestinationURL.path) {
            try fileManager.removeItem(at: coordinatedDestinationURL)
          }
          accessorError = publicationError
        } catch {
          accessorError = WorkspacePackageServiceError.rollbackFailed(
            publication: String(describing: publicationError),
            rollback: String(describing: error)
          )
        }
      }
    }
    if let accessorError { throw accessorError }
    if let coordinationError { throw coordinationError }
  }

  private func synchronizeDirectoryContents(from sourceURL: URL, to destinationURL: URL) throws {
    var destinationIsDirectory: ObjCBool = false
    if fileManager.fileExists(
      atPath: destinationURL.path,
      isDirectory: &destinationIsDirectory
    ), !destinationIsDirectory.boolValue {
      try fileManager.removeItem(at: destinationURL)
    }
    try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
    let sourceItems = try fileManager.contentsOfDirectory(
      at: sourceURL,
      includingPropertiesForKeys: Array(keys)
    )
    let sourceNames = Set(sourceItems.map(\.lastPathComponent))

    for sourceItemURL in sourceItems {
      let destinationItemURL = destinationURL.appendingPathComponent(
        sourceItemURL.lastPathComponent
      )
      let values = try sourceItemURL.resourceValues(forKeys: keys)
      if values.isDirectory == true {
        try synchronizeDirectoryContents(from: sourceItemURL, to: destinationItemURL)
      } else if values.isRegularFile == true {
        if fileManager.fileExists(atPath: destinationItemURL.path) {
          let destinationValues = try destinationItemURL.resourceValues(forKeys: keys)
          if destinationValues.isRegularFile != true {
            try fileManager.removeItem(at: destinationItemURL)
          }
        }
        if fileManager.fileExists(atPath: destinationItemURL.path),
          fileManager.contentsEqual(
            atPath: sourceItemURL.path,
            andPath: destinationItemURL.path
          )
        {
          continue
        }
        try publishData(Data(contentsOf: sourceItemURL), destinationItemURL)
      } else {
        if fileManager.fileExists(atPath: destinationItemURL.path) {
          try fileManager.removeItem(at: destinationItemURL)
        }
        try fileManager.copyItem(at: sourceItemURL, to: destinationItemURL)
      }
    }

    for destinationItemURL in try fileManager.contentsOfDirectory(
      at: destinationURL,
      includingPropertiesForKeys: nil
    ) where !sourceNames.contains(destinationItemURL.lastPathComponent) {
      try fileManager.removeItem(at: destinationItemURL)
    }
  }

  private func packageDirectory(at url: URL) throws -> URL {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      throw WorkspacePackageServiceError.packageNotFound(url)
    }
    return url
  }
}

public enum WorkspacePackageServiceError: Error, Equatable, Sendable {
  case packageNotFound(URL)
  case packageURLIsNotDirectory(URL)
  case rollbackFailed(publication: String, rollback: String)
  case jsonMirrorMismatch(String)
}
