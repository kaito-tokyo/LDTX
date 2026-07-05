// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

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
            workspace.inputDevices.append(WorkspaceInputDeviceRecord(name: "Mic", kind: .audio))
        }
        XCTAssertTrue(store.isDirty)

        try store.markSaved()
        XCTAssertFalse(store.isDirty)
    }

    func testReplacingDefinitionWithSavedEquivalentBecomesClean() throws {
        let savedDefinition = WorkspaceDefinition(
            id: "store-workspace",
            name: "Store Workspace",
            inputDevices: [
                WorkspaceInputDeviceRecord(name: "Camera", kind: .video)
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
