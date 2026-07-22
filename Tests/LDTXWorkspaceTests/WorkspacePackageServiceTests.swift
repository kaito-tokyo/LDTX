// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import Foundation
import Testing

struct WorkspacePackageServiceTests {
    @Test func saveWritesProtobufAndJSONAndLoadReadsProtobuf() throws {
        let fileManager = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
        let service = WorkspacePackageService(fileManager: fileManager)
        let workspace = WorkspaceDefinition(
            name: "Package Workspace",
            programs: [
                SavedProgramDefinitionRecord(
                    name: "Package Program",
                    canvasWidth: 1920,
                    canvasHeight: 1080,
                    frameRateNumerator: 60,
                    frameRateDenominator: 1,
                    composite: CompositeProgramDefinition()
                )
            ],
            inputDevices: [
                WorkspaceInputDeviceRecord(
                    id: "workspace-camera",
                    name: "Game Capture",
                    kind: .video,
                ),
                WorkspaceInputDeviceRecord(
                    id: "workspace-game-audio",
                    name: "Game Audio",
                    kind: .audio,
                )
            ]
        )

        try service.saveWorkspace(workspace, to: packageURL)

        #expect(fileManager.fileExists(
            atPath: packageURL.appendingPathComponent(WorkspacePackageLayout.protobufFileName).path
        ))
        #expect(fileManager.fileExists(
            atPath: packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName).path
        ))
        #expect(try service.loadWorkspace(at: packageURL) == workspace)
    }

    @Test func savePreservesWorkspaceDependenciesInPackage() throws {
        let fileManager = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
        let assetsURL = packageURL.appendingPathComponent(WorkspacePackageLayout.assetsDirectoryName)
        let assetURL = assetsURL.appendingPathComponent("background.txt")
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try Data("asset".utf8).write(to: assetURL)

        let service = WorkspacePackageService(fileManager: fileManager)
        try service.saveWorkspace(WorkspaceDefinition(name: "A"), to: packageURL)
        try service.saveWorkspace(WorkspaceDefinition(name: "B"), to: packageURL)

        #expect(try Data(contentsOf: assetURL) == Data("asset".utf8))
        #expect(try service.loadWorkspace(at: packageURL).name == "B")
    }

    @MainActor
    @Test func loadWorkspaceStoreUsesPackageProtobufAsSavedBytes() throws {
        let fileManager = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
        let service = WorkspacePackageService(fileManager: fileManager)
        try service.saveWorkspace(
            WorkspaceDefinition(name: "Stored"),
            to: packageURL
        )

        let store = try service.loadWorkspaceStore(at: packageURL)

        #expect(store.definition.name == "Stored")
        #expect(!store.isDirty)
    }

    @MainActor
    @Test func saveWorkspaceStoreMarksWrittenProtobufAsClean() throws {
        let fileManager = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
        let service = WorkspacePackageService(fileManager: fileManager)
        let store = try WorkspaceStore(clean: WorkspaceDefinition(name: "Store"))
        store.editPreferences { preferences in
            preferences.physicalDeviceIDsByInputDeviceID = ["workspace-mic": "audio-1"]
            preferences.selectedProgramName = "Store Program"
        }
        store.edit { workspace in
            workspace.programs = [
                SavedProgramDefinitionRecord(
                    name: "Store Program",
                    canvasWidth: 1280,
                    canvasHeight: 720,
                    frameRateNumerator: 30,
                    frameRateDenominator: 1,
                    composite: CompositeProgramDefinition()
                )
            ]
            workspace.inputDevices = [
                WorkspaceInputDeviceRecord(
                    id: "workspace-mic",
                    name: "Mic",
                    kind: .audio,
                )
            ]
        }
        #expect(store.isDirty)

        try service.saveWorkspaceStore(store, to: packageURL)

        #expect(!store.isDirty)
        #expect(try service.loadWorkspace(at: packageURL) == store.definition)
        #expect(try service.loadWorkspaceStore(at: packageURL).preferences == store.preferences)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDTXWorkspaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
