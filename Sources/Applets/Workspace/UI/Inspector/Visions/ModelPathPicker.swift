// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ModelPathPicker: NSViewRepresentable {
  @Binding var fileURL: URL?
  var placeholderString: LocalizedStringResource = "Choose Model…"
  var accessibilityLabel: LocalizedStringResource = "Model"

  @Environment(\.isEnabled) private var isEnabled

  func makeNSView(context: Context) -> NSPathControl {
    let control = NSPathControl()
    control.pathStyle = .popUp
    control.isEditable = true
    control.setContentHuggingPriority(.defaultLow, for: .horizontal)
    control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    control.cell?.lineBreakMode = .byTruncatingMiddle
    control.allowedTypes = Self.allowedTypes.map(\.identifier)
    control.delegate = context.coordinator
    control.target = context.coordinator
    control.action = #selector(Coordinator.pathChanged(_:))
    return control
  }

  func updateNSView(_ control: NSPathControl, context: Context) {
    control.placeholderString = String(localized: placeholderString)
    control.setAccessibilityLabel(String(localized: accessibilityLabel))
    context.coordinator.fileURL = $fileURL
    control.isEnabled = isEnabled
    control.url = fileURL
  }

  func makeCoordinator() -> Coordinator { Coordinator(fileURL: $fileURL) }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: NSPathControl, context: Context
  ) -> CGSize? {
    guard let width = proposal.width, width.isFinite else { return nil }
    return CGSize(width: width, height: nsView.intrinsicContentSize.height)
  }

  private static let allowedTypes: [UTType] = [
    UTType(filenameExtension: "mlmodel") ?? .data,
    UTType(filenameExtension: "mlpackage", conformingTo: .package) ?? .package,
  ]

  final class Coordinator: NSObject, NSPathControlDelegate {
    var fileURL: Binding<URL?>

    init(fileURL: Binding<URL?>) { self.fileURL = fileURL }

    @MainActor @objc func pathChanged(_ control: NSPathControl) {
      fileURL.wrappedValue = control.url
    }

    func pathControl(_ pathControl: NSPathControl, willDisplay openPanel: NSOpenPanel) {
      openPanel.allowedContentTypes = ModelPathPicker.allowedTypes
      openPanel.treatsFilePackagesAsDirectories = false
      openPanel.canChooseFiles = true
      openPanel.canChooseDirectories = false
      openPanel.allowsMultipleSelection = false
    }
  }
}
