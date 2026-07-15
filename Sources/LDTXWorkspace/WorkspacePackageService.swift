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

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
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
            try WorkspacePersistenceCodec.legacyPreferences(fromWorkspaceData: data)
        }
        return try WorkspaceStore(
            definition: WorkspacePersistenceCodec.decodeWorkspace(from: data),
            preferences: preferences,
            lastSavedBytes: data
        )
    }

    public func saveWorkspace(_ workspace: WorkspaceDefinition, to packageURL: URL) throws {
        let package = try preparePackageDirectory(at: packageURL)
        let protobufData = try WorkspacePersistenceCodec.encodeWorkspace(workspace)
        let jsonData = try WorkspacePersistenceCodec.encodeWorkspaceJSON(workspace)

        try writeWorkspaceFiles(protobufData: protobufData, jsonData: jsonData, to: package)
    }

    @MainActor
    public func saveWorkspaceStore(_ store: WorkspaceStore, to packageURL: URL) throws {
        let package = try preparePackageDirectory(at: packageURL)
        let protobufData = try WorkspacePersistenceCodec.encodeWorkspace(store.definition)
        let jsonData = try WorkspacePersistenceCodec.encodeWorkspaceJSON(store.definition)

        try writeWorkspaceFiles(protobufData: protobufData, jsonData: jsonData, to: package)
        try writePreferences(store.preferences, to: package)
        store.markSaved(bytes: protobufData)
    }

    @MainActor
    public func saveWorkspacePreferences(_ store: WorkspaceStore, to packageURL: URL) throws {
        try writePreferences(store.preferences, to: try preparePackageDirectory(at: packageURL))
    }

    private func writePreferences(_ preferences: WorkspacePreferences, to package: URL) throws {
        try WorkspacePersistenceCodec.encodePreferences(preferences).write(
            to: package.appendingPathComponent(WorkspacePackageLayout.preferencesProtobufFileName),
            options: [.atomic]
        )
        try WorkspacePersistenceCodec.encodePreferencesJSON(preferences).write(
            to: package.appendingPathComponent(WorkspacePackageLayout.preferencesJSONFileName),
            options: [.atomic]
        )
    }

    private func writeWorkspaceFiles(protobufData: Data, jsonData: Data, to package: URL) throws {
        try protobufData.write(
            to: package.appendingPathComponent(WorkspacePackageLayout.protobufFileName),
            options: [.atomic]
        )
        try jsonData.write(
            to: package.appendingPathComponent(WorkspacePackageLayout.jsonFileName),
            options: [.atomic]
        )
    }

    private func preparePackageDirectory(at url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw WorkspacePackageServiceError.packageURLIsNotDirectory(url)
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
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
