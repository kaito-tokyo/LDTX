// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import Testing
@testable import LDTXVision

@MainActor
@Suite("Vision runtime store")
struct VisionRuntimeStoreTests {
    @Test("Changing the model invalidates runtime state")
    func modelChangeInvalidatesRuntimeState() {
        let store = VisionRuntimeStore()
        var vision = WorkspaceVisionDefinition(
            id: "vision",
            model: WorkspaceVisionModel(repositoryID: "test/missing-model-a")
        )
        store.synchronize(visions: [vision])
        store.accept(VisionAnalysis(output: "old", elapsedSeconds: 1), for: vision)
        store.reportFailure(for: vision.id, message: "old failure")

        vision.model = WorkspaceVisionModel(repositoryID: "test/missing-model-b")
        store.synchronize(visions: [vision])

        #expect(store.status(for: vision) == .notDownloaded)
        #expect(store.resultsByVisionID[vision.id] == nil)
        #expect(store.analysesByVisionID[vision.id] == nil)
    }

    @Test("Editing prompts preserves runtime state")
    func promptChangePreservesRuntimeState() {
        let store = VisionRuntimeStore()
        var vision = WorkspaceVisionDefinition(
            id: "vision",
            model: WorkspaceVisionModel(repositoryID: "test/missing-model")
        )
        store.synchronize(visions: [vision])
        store.accept(VisionAnalysis(output: "result", elapsedSeconds: 1), for: vision)

        vision.systemPrompt = "Updated prompt"
        store.synchronize(visions: [vision])

        #expect(store.status(for: vision) == .ready)
        #expect(store.resultsByVisionID[vision.id] == "result")
        #expect(store.analysesByVisionID[vision.id]?.output == "result")
    }
}
