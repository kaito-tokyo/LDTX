// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import LDTXProtos
import LDTXProtosMacOSExtra
import Testing

@Suite(.tags(.medium)) struct VisionRegionDefaultsUnitTestSuite {
  @Test("LUB-1004: Absent fields project using input pixel defaults")
  func absentFieldsProjectUsingInputPixelDefaults() throws {
    var value = Ldtx_Workspace_V4_VisionRegionOfInterest()
    value.x.num = 320
    value.width.num = 640
    value.height.num = 180
    let resolved = try value.resolved(inputSize: (1920, 1080))
    #expect(
      resolved.rect(in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        == CGRect(x: 320, y: 0, width: 640, height: 180))
  }
}
