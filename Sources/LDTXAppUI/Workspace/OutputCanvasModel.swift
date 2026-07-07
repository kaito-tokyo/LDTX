// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import Observation

@MainActor
@Observable
public final class OutputCanvasModel {
    public struct CanvasSize: Equatable, Hashable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public struct State: Equatable {
        public var canvasSize: CanvasSize
        public var programDefinitionFrameRate: Int
        public var programVideoPTSInputKey: String?

        public init(
            canvasSize: CanvasSize,
            programDefinitionFrameRate: Int,
            programVideoPTSInputKey: String?
        ) {
            self.canvasSize = canvasSize
            self.programDefinitionFrameRate = programDefinitionFrameRate
            self.programVideoPTSInputKey = programVideoPTSInputKey
        }
    }

    public static let supportedCanvasSizes: [CanvasSize] = [
        CanvasSize(width: 1_280, height: 720),
        CanvasSize(width: 1_920, height: 1_080),
    ]

    public var canvasSize: CanvasSize
    public var programDefinitionFrameRate: Int
    public var programVideoPTSInputKey: String?

    public init(
        canvasSize: CanvasSize = CanvasSize(width: 1_920, height: 1_080),
        programDefinitionFrameRate: Int = 60,
        programVideoPTSInputKey: String? = nil
    ) {
        self.canvasSize = canvasSize
        self.programDefinitionFrameRate = programDefinitionFrameRate
        self.programVideoPTSInputKey = programVideoPTSInputKey
    }

    public var state: State {
        State(
            canvasSize: canvasSize,
            programDefinitionFrameRate: programDefinitionFrameRate,
            programVideoPTSInputKey: programVideoPTSInputKey
        )
    }

    public func sync(from record: SavedProgramDefinitionRecord?) {
        guard let record else {
            return
        }
        let recordCanvasSize = CanvasSize(width: record.canvasWidth, height: record.canvasHeight)
        canvasSize =
            Self.supportedCanvasSizes.first(where: { $0 == recordCanvasSize })
            ?? recordCanvasSize
        programDefinitionFrameRate = max(
            record.frameRateNumerator / max(record.frameRateDenominator, 1),
            1
        )
        programVideoPTSInputKey = record.composite.programVideoPTSInputKey
    }

    public func applying(to composite: CompositeProgramDefinition) -> CompositeProgramDefinition {
        var composite = composite
        composite.programVideoPTSInputKey = programVideoPTSInputKey
        return composite
    }
}
