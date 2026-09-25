// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct ItemNameDialog: View {
  @Binding var name: String
  let title: String
  let fieldTitle: String
  let isNameAvailable: (String) -> Bool
  let submit: (String) -> Void
  let cancel: () -> Void
  @FocusState private var isNameFieldFocused: Bool

  var candidate: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var canSubmit: Bool {
    !candidate.isEmpty && isNameAvailable(candidate)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.headline)
      TextField(fieldTitle, text: $name)
        .focused($isNameFieldFocused)
        .onSubmit { if canSubmit { submit(candidate) } }
      if !candidate.isEmpty, !isNameAvailable(candidate) {
        Text("An item with this name already exists.")
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
        Button("Add") { submit(candidate) }
          .keyboardShortcut(.defaultAction)
          .disabled(!canSubmit)
      }
    }
    .padding(20)
    .frame(width: 360)
    .onAppear { isNameFieldFocused = true }
  }
}
