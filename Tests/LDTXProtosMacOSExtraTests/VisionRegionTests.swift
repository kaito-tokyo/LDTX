// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import LDTXCorelibs
import LDTXProtosMacOSExtra
import Testing

@Suite(.tags(.medium)) struct VisionRegionUnitTestSuite {
  private func region() -> Ldtx_Workspace_V4_VisionRegionOfInterest {
    .with {
      $0.x = .with {
        $0.num = 1
        $0.den = 4
      }
      $0.y = .with {
        $0.num = 1
        $0.den = 2
      }
      $0.width = .with {
        $0.num = 1
        $0.den = 2
      }
      $0.height = .with {
        $0.num = 1
        $0.den = 4
      }
    }
  }

  @Test("LUB-1004: Projects using image origin and size") func projectsUsingImageOriginAndSize()
    throws
  {
    let value = region()
    let before = try value.serializedData()
    #expect(
      value.rect(in: CGRect(x: 100, y: -20, width: 800, height: 400))
        == CGRect(x: 300, y: 180, width: 400, height: 100))
    #expect(try value.serializedData() == before)
  }

  @Test("LUB-1004: Defaults project to the entire image") func defaultsProjectToTheEntireImage() {
    let extent = CGRect(x: 10, y: -20, width: 800, height: 400)
    let value = Ldtx_Workspace_V4_VisionRegionOfInterest()
    #expect(value.rect(in: extent) == extent)
    #expect(!value.hasWidth && !value.hasHeight)
  }

  @Test("LUB-1004: Projection uses fixed defaults for unset components")
  func projectionUsesFixedDefaultsForUnsetComponents() {
    var value = region()
    value.clearX()
    value.width.clearNum()
    let rect = value.rect(in: CGRect(x: 10, y: 20, width: 100, height: 100))
    #expect(rect.minX == 10)
    #expect(rect.width == 50)
    #expect(!value.hasX && !value.width.hasNum)
  }
}
