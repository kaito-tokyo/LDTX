// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import XCTest

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    func testCleanStoreIsNotDirtyUntilDefinitionChanges() throws {
        let store = try WorkspaceStore(clean: WorkspaceDefinition(
            id: "store-workspace",
            name: "Store Workspace"
        ))

        XCTAssertFalse(store.isDirty)

        store.edit { workspace in
            workspace.name = "Edited Workspace"
        }

        XCTAssertTrue(store.isDirty)
    }

    func testMarkSavedUsesCurrentProtobufBytesAsDirtyTruth() throws {
        let store = try WorkspaceStore(clean: WorkspaceDefinition(
            id: "store-workspace",
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
        XCTAssertTrue(store.isDirty)

        try store.markSaved()
        XCTAssertFalse(store.isDirty)
    }

    func testReplacingDefinitionWithSavedEquivalentBecomesClean() throws {
        let savedDefinition = WorkspaceDefinition(
            id: "store-workspace",
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
            definition: WorkspaceDefinition(id: "other", name: "Other"),
            lastSavedBytes: savedBytes
        )

        XCTAssertTrue(store.isDirty)

        store.replaceDefinition(savedDefinition)

        XCTAssertFalse(store.isDirty)
    }
}
