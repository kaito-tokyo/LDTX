// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import Foundation
import Testing

struct WorkspacePackageServiceTests {
    @MainActor
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

        try service.saveWorkspaceStore(try WorkspaceStore(clean: workspace), to: packageURL)

        #expect(fileManager.fileExists(
            atPath: packageURL.appendingPathComponent(WorkspacePackageLayout.protobufFileName).path
        ))
        #expect(fileManager.fileExists(
            atPath: packageURL.appendingPathComponent(WorkspacePackageLayout.jsonFileName).path
        ))
        #expect(try service.loadWorkspace(at: packageURL) == workspace)
    }

    @MainActor
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
        try service.saveWorkspaceStore(
            try WorkspaceStore(clean: WorkspaceDefinition(name: "A")),
            to: packageURL
        )
        try service.saveWorkspaceStore(
            try WorkspaceStore(clean: WorkspaceDefinition(name: "B")),
            to: packageURL
        )

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
        try service.saveWorkspaceStore(
            try WorkspaceStore(clean: WorkspaceDefinition(name: "Stored")),
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

    @MainActor
    @Test func savingStoreAlsoPreservesTheWorkspaceDefinition() throws {
        let fileManager = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
        let service = WorkspacePackageService(fileManager: fileManager)
        let store = try WorkspaceStore(clean: WorkspaceDefinition(
            programs: [SavedProgramDefinitionRecord(
                name: "Main",
                canvasWidth: 1920,
                canvasHeight: 1080,
                frameRateNumerator: 60,
                frameRateDenominator: 1,
                composite: CompositeProgramDefinition()
            )],
            inputDevices: [WorkspaceInputDeviceRecord(name: "Camera", kind: .video)],
            videoComponents: [
                WorkspaceVideoComponentRecord(
                    name: "Camera Component",
                    component: .inputCameraDevice(InputDeviceComponent(
                        inputDeviceID: "Camera",
                        destinationX: 120,
                        destinationY: 80,
                        destinationScale: 0.5
                    ))
                )
            ]
        ))
        store.editPreferences { $0.selectedProgramName = "Main" }

        try service.saveWorkspaceStore(store, to: packageURL)

        let reloaded = try service.loadWorkspaceStore(at: packageURL)
        let component = try #require(reloaded.definition.videoComponents.first?.component)
        guard case let .inputCameraDevice(payload) = component else {
            Issue.record("Expected an input camera component")
            return
        }
        #expect(payload.destinationX == 120)
        #expect(payload.destinationY == 80)
        #expect(payload.destinationScale == 0.5)
        #expect(reloaded.preferences.selectedProgramName == "Main")
    }

    @MainActor
    @Test func failedStagingWriteLeavesExistingPackageAndStoreUntouched() throws {
        let fileManager = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Studio.ldtxworkspace")
        let initialStore = try WorkspaceStore(clean: WorkspaceDefinition(name: "Before"))
        try WorkspacePackageService().saveWorkspaceStore(initialStore, to: packageURL)

        let store = try WorkspacePackageService().loadWorkspaceStore(at: packageURL)
        store.edit { $0.name = "After" }
        let service = WorkspacePackageService(writeData: { data, url in
            if url.lastPathComponent == WorkspacePackageLayout.preferencesProtobufFileName {
                throw TestWriteError.injectedFailure
            }
            try data.write(to: url, options: [.atomic])
        })

        #expect(throws: TestWriteError.injectedFailure) {
            try service.saveWorkspaceStore(store, to: packageURL)
        }
        #expect(store.isDirty)
        #expect(try WorkspacePackageService().loadWorkspace(at: packageURL).name == "Before")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDTXWorkspaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum TestWriteError: Error, Equatable {
    case injectedFailure
}
