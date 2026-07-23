// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import Testing

@MainActor
struct WorkspaceStoreTests {
    @Test func cleanStoreIsNotDirtyUntilDefinitionChanges() throws {
        let store = try WorkspaceStore(clean: WorkspaceDefinition(
            name: "Store Workspace"
        ))

        #expect(!store.isDirty)

        store.edit { workspace in
            workspace.name = "Edited Workspace"
        }

        #expect(store.isDirty)
    }

    @Test func markSavedUsesCurrentProtobufBytesAsDirtyTruth() throws {
        let store = try WorkspaceStore(clean: WorkspaceDefinition(
            name: "Store Workspace"
        ))

        store.edit { workspace in
            workspace.programs = [
                SavedProgramDefinitionRecord(
                    name: "Store Program",
                    canvasWidth: 1280,
                    canvasHeight: 720,
                    frameRateNumerator: 30,
                    frameRateDenominator: 1,
                    composite: CompositeProgramDefinition(),
                    inputDevices: [
                        WorkspaceInputDeviceRecord(
                            id: "workspace-mic",
                            name: "Mic",
                            kind: .audio,
                            physicalDeviceID: "audio-1"
                        )
                    ]
                )
            ]
        }
        #expect(store.isDirty)

        try store.markSaved()
        #expect(!store.isDirty)
    }

    @Test func replacingDefinitionWithSavedEquivalentBecomesClean() throws {
        let savedDefinition = WorkspaceDefinition(
            name: "Store Workspace",
            programs: [
                SavedProgramDefinitionRecord(
                    name: "Saved Program",
                    canvasWidth: 1920,
                    canvasHeight: 1080,
                    frameRateNumerator: 60,
                    frameRateDenominator: 1,
                    composite: CompositeProgramDefinition(),
                    inputDevices: [
                        WorkspaceInputDeviceRecord(
                            id: "workspace-camera",
                            name: "Camera",
                            kind: .video,
                            physicalDeviceID: "camera-1"
                        )
                    ]
                )
            ]
        )
        let savedBytes = try WorkspacePersistenceCodec.encodeWorkspace(savedDefinition)
        let store = WorkspaceStore(
            definition: WorkspaceDefinition(name: "Other"),
            lastSavedBytes: savedBytes
        )

        #expect(store.isDirty)

        store.replaceDefinition(savedDefinition)

        #expect(!store.isDirty)
    }

    @Test func replacePublishesDefinitionAndPreferencesTogether() throws {
        let store = try WorkspaceStore(clean: WorkspaceDefinition(name: "Original"))
        let preferences = WorkspacePreferences(selectedProgramName: "Renamed Program")

        store.replace(
            definition: WorkspaceDefinition(name: "Renamed"),
            preferences: preferences
        )

        #expect(store.definition.name == "Renamed")
        #expect(store.preferences == preferences)
    }
}
