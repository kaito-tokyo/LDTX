// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum WorkspacePackageLayout {
    public static let pathExtension = "ldtxworkspace"
    public static let protobufFileName = "workspace.pb"
    public static let jsonFileName = "workspace.json"
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
        return try WorkspaceStore(
            definition: WorkspacePersistenceCodec.decodeWorkspace(from: data),
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
        store.markSaved(bytes: protobufData)
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
