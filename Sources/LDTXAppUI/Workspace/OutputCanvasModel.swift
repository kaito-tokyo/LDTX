// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import Observation

@MainActor
@Observable
public final class OutputCanvasModel {
    public struct State: Equatable {
        public var programDefinitionFrameRate: Int
        public var programVideoPTSInputKey: String?
        public var programAudioPTSInputKey: String?

        public init(
            programDefinitionFrameRate: Int,
            programVideoPTSInputKey: String?,
            programAudioPTSInputKey: String?
        ) {
            self.programDefinitionFrameRate = programDefinitionFrameRate
            self.programVideoPTSInputKey = programVideoPTSInputKey
            self.programAudioPTSInputKey = programAudioPTSInputKey
        }
    }

    public var programDefinitionFrameRate: Int
    public var programVideoPTSInputKey: String?
    public var programAudioPTSInputKey: String?

    public init(
        programDefinitionFrameRate: Int = 60,
        programVideoPTSInputKey: String? = nil,
        programAudioPTSInputKey: String? = nil
    ) {
        self.programDefinitionFrameRate = programDefinitionFrameRate
        self.programVideoPTSInputKey = programVideoPTSInputKey
        self.programAudioPTSInputKey = programAudioPTSInputKey
    }

    public var state: State {
        State(
            programDefinitionFrameRate: programDefinitionFrameRate,
            programVideoPTSInputKey: programVideoPTSInputKey,
            programAudioPTSInputKey: programAudioPTSInputKey
        )
    }

    public func sync(from record: SavedProgramDefinitionRecord?) {
        guard let record else {
            return
        }
        programDefinitionFrameRate = max(
            record.frameRateNumerator / max(record.frameRateDenominator, 1),
            1
        )
        programVideoPTSInputKey = record.composite.programVideoPTSInputKey
        programAudioPTSInputKey = record.composite.programAudioPTSInputKey
    }

    public func applying(to composite: CompositeProgramDefinition) -> CompositeProgramDefinition {
        var composite = composite
        composite.programVideoPTSInputKey = programVideoPTSInputKey
        composite.programAudioPTSInputKey = programAudioPTSInputKey
        return composite
    }
}
