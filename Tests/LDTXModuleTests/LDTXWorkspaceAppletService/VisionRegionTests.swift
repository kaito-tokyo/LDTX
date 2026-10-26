// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import LDTXCorelibs
@testable import LDTXWorkspaceAppletService
import Testing

@Suite(.tags(.medium))
struct VisionRegionUnitTestSuite {
  private func region() -> Ldtx_Workspace_V4_VisionRegionOfInterest {
    .with {
      $0.x = .with { $0.num = 1; $0.den = 4 }
      $0.y = .with { $0.num = 1; $0.den = 2 }
      $0.width = .with { $0.num = 1; $0.den = 2 }
      $0.height = .with { $0.num = 1; $0.den = 4 }
    }
  }

  @Test("Projects using image origin and size")
  func projectsUsingImageOriginAndSize() throws {
    let value = region()
    let before = try value.serializedData()
    #expect(
      value.rect(in: CGRect(x: 100, y: -20, width: 800, height: 400))
        == CGRect(x: 300, y: 180, width: 400, height: 100))
    #expect(try value.serializedData() == before)
  }

  @Test("Defaults project to the entire image")
  func defaultsProjectToTheEntireImage() {
    let extent = CGRect(x: 10, y: -20, width: 800, height: 400)
    let value = Ldtx_Workspace_V4_VisionRegionOfInterest()
    #expect(value.rect(in: extent) == extent)
    #expect((value.width == nil) && (value.height == nil))
  }

  @Test("Projection uses fixed defaults for unset components")
  func projectionUsesFixedDefaultsForUnsetComponents() {
    var value = region()
    value.x = nil
    value.width?.num = nil
    let rect = value.rect(in: CGRect(x: 10, y: 20, width: 100, height: 100))
    #expect(rect.minX == 10)
    #expect(rect.width == 50)
    #expect((value.x == nil) && (value.width?.num == nil))
  }

  @Test("Absent fields project using input pixel defaults")
  func absentFieldsProjectUsingInputPixelDefaults() throws {
    var value = Ldtx_Workspace_V4_VisionRegionOfInterest()
    value.x = .with { $0.num = 320 }
    value.width = .with { $0.num = 640 }
    value.height = .with { $0.num = 180 }
    let resolved = try value.resolved(inputSize: (1920, 1080))
    #expect(
      resolved.rect(in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        == CGRect(x: 320, y: 0, width: 640, height: 180))
  }
}
