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

  private static let allowedTypes: [UTType] = [UTType(filenameExtension: "mlmodel") ?? .data]

  final class Coordinator: NSObject, NSPathControlDelegate {
    var fileURL: Binding<URL?>

    init(fileURL: Binding<URL?>) { self.fileURL = fileURL }

    @MainActor @objc func pathChanged(_ control: NSPathControl) {
      fileURL.wrappedValue = control.url
    }

    func pathControl(_ pathControl: NSPathControl, willDisplay openPanel: NSOpenPanel) {
      openPanel.canChooseFiles = true
      openPanel.canChooseDirectories = false
      openPanel.allowsMultipleSelection = false
      openPanel.allowedContentTypes = ModelPathPicker.allowedTypes
    }
  }
}
