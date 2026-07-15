// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRendering
import LDTXVideoComposition
import simd
import Testing

struct ProgramRenderingOrderTests {
    @Test func compositeRenderingUsesLastVideoComponentAsBottomLayer() throws {
        let composite = CompositeProgramDefinition(steps: [
            CompositeProgramStep(component: .fillSolidColor(FillSolidColorComponent(
                red: 1,
                green: 0,
                blue: 0,
                alpha: 1
            ))),
            CompositeProgramStep(component: .fillSolidColor(FillSolidColorComponent(
                red: 0,
                green: 1,
                blue: 0,
                alpha: 1
            )))
        ])

        let components = composite.components(
            width: 64,
            height: 64,
            source: nil,
            timeSeconds: 0
        )
        let commands = components.map { $0.makeCommand() }

        let first = try #require(commands.first)
        let last = try #require(commands.last)
        guard case let .solidColor(bottom) = first,
              case let .solidColor(top) = last else {
            Issue.record("Expected solid-color commands in rendered order.")
            return
        }

        #expect(bottom.color == SIMD4<Float>(0, 1, 0, 1))
        #expect(top.color == SIMD4<Float>(1, 0, 0, 1))
    }
}
