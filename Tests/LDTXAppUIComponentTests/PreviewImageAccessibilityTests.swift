// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite struct PreviewImageAccessibilityUnitTestSuite {
    @Test("LUB-1058: Identity and selection actions") @MainActor func identityAndSelectionActions()
      throws
    {
      let host = NSView()
      var landscape = 0
      var portrait = 0
      let element = PreviewImageAccessibilityElement(
        host: host, store: nil,
        selectLandscape: { landscape += 1 }, selectPortrait: { portrait += 1 })
      #expect(!element.accessibilityIsIgnored())
      #expect(element.accessibilityAttributeValue(.identifier) as? String == "canvasPairPreview")
      #expect(
        element.accessibilityAttributeValue(.role) as? String == NSAccessibility.Role.image.rawValue
      )
      #expect(
        element.accessibilityParameterizedAttributeNames().contains(.init(rawValue: "AXImageData")))
      let actions = try #require(
        element.accessibilityAttributeValue(.init(rawValue: "AXCustomActions"))
          as? [NSAccessibilityCustomAction])
      #expect(actions.count == 2)
      #expect(actions[0].handler?() == true)
      #expect(actions[1].handler?() == true)
      #expect(landscape == 1 && portrait == 1)
      #expect(
        element.accessibilityAttributeValue(
          .init(rawValue: "AXImageData"),
          forParameter: ["AXImageDataFormat": "RGBA"]) == nil)
    }
  }
}
