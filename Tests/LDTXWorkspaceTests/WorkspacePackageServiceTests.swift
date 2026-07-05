// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import XCTest

final class WorkspacePackageServiceTests: XCTestCase {
    func testSaveWritesProtobufAndJSONAndLoadReadsProtobuf() throws {
        let fileManager = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
        let service = WorkspacePackageService(fileManager: fileManager)
        let workspace = WorkspaceDefinition(
            id: "package-workspace",
            name: "Package Workspace",
            inputDevices: [
                WorkspaceInputDeviceRecord(name: "Game Capture", kind: .video),
                WorkspaceInputDeviceRecord(name: "Game Audio", kind: .audio)
            ]
        )

        try service.saveWorkspace(workspace, to: packageURL)

        XCTAssertTrue(fileManager.fileExists(
            atPath: packageURL.appendingPathComponent(WorkspacePackageLayout.protobufFileName).path
        ))
        XCTAssertTrue(fileManager.fileExists(
            atPath: packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName).path
        ))
        XCTAssertEqual(try service.loadWorkspace(at: packageURL), workspace)
    }

    func testSavePreservesWorkspaceDependenciesInPackage() throws {
        let fileManager = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
        let assetsURL = packageURL.appendingPathComponent(WorkspacePackageLayout.assetsDirectoryName)
        let assetURL = assetsURL.appendingPathComponent("background.txt")
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try Data("asset".utf8).write(to: assetURL)

        let service = WorkspacePackageService(fileManager: fileManager)
        try service.saveWorkspace(WorkspaceDefinition(id: "a", name: "A"), to: packageURL)
        try service.saveWorkspace(WorkspaceDefinition(id: "b", name: "B"), to: packageURL)

        XCTAssertEqual(try Data(contentsOf: assetURL), Data("asset".utf8))
        XCTAssertEqual(try service.loadWorkspace(at: packageURL).id, "b")
    }

    @MainActor
    func testLoadWorkspaceStoreUsesPackageProtobufAsSavedBytes() throws {
        let fileManager = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
        let service = WorkspacePackageService(fileManager: fileManager)
        try service.saveWorkspace(
            WorkspaceDefinition(id: "stored", name: "Stored"),
            to: packageURL
        )

        let store = try service.loadWorkspaceStore(at: packageURL)

        XCTAssertEqual(store.definition.id, "stored")
        XCTAssertFalse(store.isDirty)
    }

    @MainActor
    func testSaveWorkspaceStoreMarksWrittenProtobufAsClean() throws {
        let fileManager = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
        let service = WorkspacePackageService(fileManager: fileManager)
        let store = try WorkspaceStore(clean: WorkspaceDefinition(id: "store", name: "Store"))
        store.edit { workspace in
            workspace.inputDevices.append(WorkspaceInputDeviceRecord(name: "Mic", kind: .audio))
        }
        XCTAssertTrue(store.isDirty)

        try service.saveWorkspaceStore(store, to: packageURL)

        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(try service.loadWorkspace(at: packageURL), store.definition)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDTXWorkspaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
