// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import LDTXProtos
import LDTXProtosMacOSExtra
import Testing

@Suite struct VisionRegionTests {
  private func region() -> Ldtx_Workspace_V4_VisionRegionOfInterest {
    .with {
      $0.x = .with {
        $0.numerator = 1
        $0.denominator = 4
      }
      $0.y = .with {
        $0.numerator = 1
        $0.denominator = 2
      }
      $0.width = .with {
        $0.numerator = 1
        $0.denominator = 2
      }
      $0.height = .with {
        $0.numerator = 1
        $0.denominator = 4
      }
    }
  }

  @Test func projectsUsingImageOriginAndSize() throws {
    let value = region()
    let before = try value.serializedData()
    #expect(
      value.rect(in: CGRect(x: 100, y: -20, width: 800, height: 400))
        == CGRect(x: 300, y: 180, width: 400, height: 100))
    #expect(try value.serializedData() == before)
  }

  @Test func defaultsProjectToTheEntireImage() {
    let extent = CGRect(x: 10, y: -20, width: 800, height: 400)
    let value = Ldtx_Workspace_V4_VisionRegionOfInterest()
    #expect(value.rect(in: extent) == extent)
    #expect(!value.hasWidth && !value.hasHeight)
  }

  @Test func projectionUsesFixedDefaultsForUnsetComponents() {
    var value = region()
    value.clearX()
    value.width.clearNumerator()
    let rect = value.rect(in: CGRect(x: 10, y: 20, width: 100, height: 100))
    #expect(rect.minX == 10)
    #expect(rect.width == 50)
    #expect(!value.hasX && !value.width.hasNumerator)
  }
}
