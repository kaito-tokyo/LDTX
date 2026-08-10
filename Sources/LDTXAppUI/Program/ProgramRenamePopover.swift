// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

public struct ProgramNameDialog: View {
  @Binding private var name: String
  private var title: String
  private var actionTitle: String
  private var currentName: String?
  private var isNameAvailable: (String) -> Bool
  private var submit: () -> Void
  private var cancel: () -> Void
  @FocusState private var isNameFieldFocused: Bool

  public init(
    name: Binding<String>,
    title: String,
    actionTitle: String,
    currentName: String? = nil,
    isNameAvailable: @escaping (String) -> Bool = { _ in true },
    submit: @escaping () -> Void,
    cancel: @escaping () -> Void
  ) {
    _name = name
    self.title = title
    self.actionTitle = actionTitle
    self.currentName = currentName
    self.isNameAvailable = isNameAvailable
    self.submit = submit
    self.cancel = cancel
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSubmit: Bool {
    !trimmedName.isEmpty && trimmedName != currentName && isNameAvailable(trimmedName)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title)
        .font(.headline)

      TextField("Program Name", text: $name)
        .focused($isNameFieldFocused)
        .onSubmit {
          if canSubmit {
            submit()
          }
        }
        .accessibilityIdentifier("programNameField")

      if !trimmedName.isEmpty, trimmedName != currentName, !isNameAvailable(trimmedName) {
        Text("A Program with this name already exists.")
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()

        Button("Cancel", role: .cancel, action: cancel)
          .keyboardShortcut(.cancelAction)

        Button(actionTitle, action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(!canSubmit)
          .accessibilityIdentifier("confirmProgramNameButton")
      }
    }
    .padding(20)
    .frame(width: 360)
    .onAppear {
      isNameFieldFocused = true
    }
  }
}

#if DEBUG
  #Preview("Program Name Dialog") {
    @Previewable @State var name = "Weekly Show"

    ProgramNameDialog(
      name: $name,
      title: "Rename Program",
      actionTitle: "Rename",
      currentName: "Demo Program",
      submit: {},
      cancel: {}
    )
  }
#endif
