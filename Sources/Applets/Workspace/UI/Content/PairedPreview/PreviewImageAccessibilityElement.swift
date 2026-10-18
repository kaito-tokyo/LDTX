// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProgramRuntime

// Legacy AX callbacks are serviced synchronously on AppKit's main thread.
private struct AXCallbackValue: @unchecked Sendable { let value: Any? }

/// The string-based AXImageData contract is implemented by WebKit, but is not declared
/// in the public AppKit SDK. Keep it behind a dedicated legacy AX element: NSView's
/// modern accessibility bridge does not advertise these parameterized attributes.
@MainActor
final class PreviewImageAccessibilityElement: NSObject {
  private weak var host: NSView?
  private let store: PreviewAccessibilityImageStore?
  private let selectLandscape: () -> Void
  private let selectPortrait: () -> Void

  init(
    host: NSView, store: PreviewAccessibilityImageStore?,
    selectLandscape: @escaping () -> Void, selectPortrait: @escaping () -> Void
  ) {
    self.host = host
    self.store = store
    self.selectLandscape = selectLandscape
    self.selectPortrait = selectPortrait
  }

  override func accessibilityIsIgnored() -> Bool { false }
  override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
    [
      "AXRole", "AXRoleDescription", "AXParent", "AXWindow", "AXTopLevelUIElement",
      "AXPosition", "AXSize", "AXDescription", "AXIdentifier", "AXEnabled",
      "AXImageDataSize", "AXCustomActions",
    ].map { NSAccessibility.Attribute(rawValue: $0) }
  }
  override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
    MainActor.assumeIsolated { AXCallbackValue(value: attributeValue(attribute)) }.value
  }

  private func attributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
    let frame =
      host.flatMap { host in
        host.window.map { $0.convertToScreen(host.convert(host.bounds, to: nil)) }
      } ?? .zero
    switch attribute.rawValue {
    case "AXRole": return NSAccessibility.Role.image.rawValue
    case "AXRoleDescription": return NSAccessibility.Role.image.description(with: nil)
    case "AXParent": return host.flatMap { NSAccessibility.unignoredAncestor(of: $0) }
    case "AXWindow", "AXTopLevelUIElement": return host?.window
    case "AXPosition": return NSValue(point: frame.origin)
    case "AXSize": return NSValue(size: frame.size)
    case "AXDescription": return String(localized: "Landscape and Portrait preview")
    case "AXIdentifier": return "canvasPairPreview"
    case "AXEnabled": return true
    case "AXImageDataSize": return NSValue(size: store?.size ?? .zero)
    case "AXCustomActions":
      return [
        NSAccessibilityCustomAction(
          name: String(localized: "Select Landscape"),
          handler: { [weak self] in
            guard let self else { return false }
            self.selectLandscape()
            return true
          }),
        NSAccessibilityCustomAction(
          name: String(localized: "Select Portrait"),
          handler: { [weak self] in
            guard let self else { return false }
            self.selectPortrait()
            return true
          }),
      ]
    default: return nil
    }
  }
  override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
    false
  }
  override func accessibilityParameterizedAttributeNames() -> [NSAccessibility
    .ParameterizedAttribute]
  {
    [NSAccessibility.ParameterizedAttribute(rawValue: "AXImageData")]
  }
  override func accessibilityAttributeValue(
    _ attribute: NSAccessibility.ParameterizedAttribute, forParameter parameter: Any?
  ) -> Any? {
    let argument = AXCallbackValue(value: parameter)
    return MainActor.assumeIsolated {
      AXCallbackValue(value: imageData(attribute, parameter: argument.value))
    }.value
  }

  private func imageData(_ attribute: NSAccessibility.ParameterizedAttribute, parameter: Any?)
    -> Any?
  {
    guard attribute.rawValue == "AXImageData", let parameters = parameter as? NSDictionary,
      host?.window != nil
    else { return nil }
    return store?.data(for: parameters)
  }
}
