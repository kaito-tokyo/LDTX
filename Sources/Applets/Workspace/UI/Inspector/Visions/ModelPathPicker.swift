// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers

struct ModelPathPicker: View {
  @Binding var fileURL: URL?
  var placeholderString: LocalizedStringResource = "Choose Model…"
  var accessibilityLabel: LocalizedStringResource = "Model"
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.workspaceReportError) private var reportError
  @State private var isImporting = false

  var body: some View {
    HStack {
      Button {
        isImporting = true
      } label: {
        if let fileURL {
          Text(fileURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
        } else {
          Text(String(localized: placeholderString))
        }
      }
      .accessibilityLabel(String(localized: accessibilityLabel))
      if fileURL != nil {
        Button("Clear", systemImage: "xmark.circle") { fileURL = nil }
          .labelStyle(.iconOnly)
      }
    }
    .fileImporter(
      isPresented: $isImporting,
      allowedContentTypes: [
        UTType(filenameExtension: "mlmodel") ?? .data,
        UTType(filenameExtension: "mlpackage", conformingTo: .package) ?? .package,
      ]
    ) { result in
      guard isEnabled else { return }
      do { fileURL = try result.get() } catch { reportError(error) }
    }
  }
}
