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

    @Test("OCR is ready without a downloaded language model")
    func ocrIsImmediatelyReady() {
        let store = VisionRuntimeStore()
        var vision = WorkspaceVisionDefinition(id: "ocr", name: "OCR")
        vision.definition = .opticalCharacterRecognition(.init(
            recognitionLevel: .accurate,
            recognitionLanguages: ["ja-JP"]
        ))

        store.synchronize(visions: [vision])

        #expect(store.status(for: vision) == .ready)
    }

    @Test("A repeated load request for the same resource is discarded")
    func repeatedModelLoadIsDiscarded() async throws {
        let service = VisionModelService()
        let model = WorkspaceVisionModel(repositoryID: "test/model-that-is-not-downloaded")

        await #expect(throws: VisionModelServiceError.self) {
            try await service.load(model: model)
        }
        try await service.load(model: model)

        #expect(await !service.isLoaded(model: model))
    }
}
