// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import Testing

@Suite
struct ProgramComponentPersistenceUnitTestSuite {
  @Test func inputDestinationDecodesLegacyUniformScale() throws {
    let data = Data(#"{"x":120,"y":80,"scale":1.5}"#.utf8)

    let destination = try JSONDecoder().decode(InputDeviceDestination.self, from: data)

    #expect(destination.x == 120)
    #expect(destination.y == 80)
    #expect(destination.scaleX == 1.5)
    #expect(destination.scaleY == 1.5)
  }

  @Test func clockCSSBackgroundValidationUsesRenderingGrammar() throws {
    #expect(ClockCSSBackground.isValid(""))
    #expect(ClockCSSBackground.isValid("#10203080"))
    #expect(ClockCSSBackground.isValid("rgba(16, 32, 48, 0.5)"))
    #expect(ClockCSSBackground.isValid("linear-gradient(90deg, #102030, transparent)"))
    #expect(!ClockCSSBackground.isValid("not-a-background"))
    #expect(!ClockCSSBackground.isValid("linear-gradient(nandeg, #000, #fff)"))
    #expect(!ClockCSSBackground.isValid("linear-gradient(infdeg, #000, #fff)"))

    let empty = try #require(ClockCSSBackground.parse(""))
    #expect(empty == .solid(.clear))
  }

  @Test func emptyClockProtobufUsesDomainDefaults() {
    var proto = Ldtx_Program_V1_ProgramComponent()
    proto.clock = Ldtx_Program_V1_ClockComponent()

    #expect(
      ProgramPersistenceCodec.decodeProgramComponent(proto) == .clock(ClockComponent())
    )
  }

  @Test func clockProtobufPreservesExplicitFalsePresentationSettings() {
    var clock = Ldtx_Program_V1_ClockComponent()
    clock.showsSeconds = false
    clock.uses24HourTime = false
    var proto = Ldtx_Program_V1_ProgramComponent()
    proto.clock = clock

    let decoded = ProgramPersistenceCodec.decodeProgramComponent(proto)
    guard case .clock(let component) = decoded else {
      Issue.record("Expected a Clock component.")
      return
    }
    #expect(!component.showsSeconds)
    #expect(!component.uses24HourTime)
    #expect(component.destinationWidth == ClockComponent().destinationWidth)
    #expect(component.foregroundAlpha == ClockComponent().foregroundAlpha)
    #expect(component.backgroundAlpha == ClockComponent().backgroundAlpha)
  }

  @Test func componentDefinitionsDoNotPersistVideoLayerPlacement() {
    let input = ProgramPersistenceCodec.decodeProgramComponent(
      ProgramPersistenceCodec.encodeProgramComponent(
        .inputCameraDevice(
          InputDeviceComponent(
            destinationX: 120,
            destinationY: 80,
            destinationScale: 1.5
          )))
    )
    guard case .inputCameraDevice(let inputPayload) = input else {
      Issue.record("Expected Input Device")
      return
    }
    #expect(inputPayload.destination == InputDeviceDestination())

    let clock = ProgramPersistenceCodec.decodeProgramComponent(
      ProgramPersistenceCodec.encodeProgramComponent(
        .clock(
          ClockComponent(
            destinationX: 0.2,
            destinationY: 0.3,
            destinationWidth: 0.4,
            destinationHeight: 0.5
          )))
    )
    guard case .clock(let clockPayload) = clock else {
      Issue.record("Expected Clock")
      return
    }
    #expect(clockPayload.destinationX == ClockComponent().destinationX)
    #expect(clockPayload.destinationY == ClockComponent().destinationY)
    #expect(clockPayload.destinationWidth == ClockComponent().destinationWidth)
    #expect(clockPayload.destinationHeight == ClockComponent().destinationHeight)
  }
}
