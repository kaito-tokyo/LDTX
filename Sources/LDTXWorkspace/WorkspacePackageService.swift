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
    private let writeData: (Data, URL) throws -> Void

    public init(
        fileManager: FileManager = .default,
        writeData: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: [.atomic])
        }
    ) {
        self.fileManager = fileManager
        self.writeData = writeData
    }

    public func loadWorkspace(at packageURL: URL) throws -> WorkspaceDefinition {
        let package = try packageDirectory(at: packageURL)
        let data = try Data(contentsOf: package.appendingPathComponent(WorkspacePackageLayout.protobufFileName))
        return try WorkspacePersistenceCodec.decodeWorkspace(from: data)
    }

    @MainActor
    public func loadWorkspaceStore(at packageURL: URL) throws -> WorkspaceStore {
        let package = try packageDirectory(at: packageURL)
        let data = try Data(contentsOf: package.appendingPathComponent(WorkspacePackageLayout.protobufFileName))
        let preferencesURL = package.appendingPathComponent(WorkspacePackageLayout.preferencesProtobufFileName)
        let preferences = if fileManager.fileExists(atPath: preferencesURL.path) {
            try WorkspacePersistenceCodec.decodePreferences(from: Data(contentsOf: preferencesURL))
        } else {
            WorkspacePreferences()
        }
        let normalized = try WorkspacePersistenceCodec.decodeWorkspace(
            from: data,
            preferences: preferences
        )
        return WorkspaceStore(
            definition: normalized.definition,
            preferences: normalized.preferences,
            lastSavedBytes: data
        )
    }

    @MainActor
    public func saveWorkspaceStore(_ store: WorkspaceStore, to packageURL: URL) throws {
        let protobufData = try WorkspacePersistenceCodec.encodeWorkspace(store.definition)
        let jsonData = try WorkspacePersistenceCodec.encodeWorkspaceJSON(store.definition)
        let preferencesProtobufData = try WorkspacePersistenceCodec.encodePreferences(store.preferences)
        let preferencesJSONData = try WorkspacePersistenceCodec.encodePreferencesJSON(store.preferences)

        try replacePackage(
            at: packageURL,
            workspaceProtobufData: protobufData,
            workspaceJSONData: jsonData,
            preferencesProtobufData: preferencesProtobufData,
            preferencesJSONData: preferencesJSONData
        )
        store.markSaved(bytes: protobufData)
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
            // Workspace locking lives beside the package. Remove the obsolete
            // in-package lock from older packages so it cannot be carried into
            // the next generation.
            let legacyLockURL = stagingURL.appendingPathComponent("LDTX.lock")
            if fileManager.fileExists(atPath: legacyLockURL.path) {
                try fileManager.removeItem(at: legacyLockURL)
            }
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

    private func packageDirectory(at url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspacePackageServiceError.packageNotFound(url)
        }
        return url
    }
}

public enum WorkspacePackageServiceError: Error, Equatable, Sendable {
    case packageNotFound(URL)
    case packageURLIsNotDirectory(URL)
}
