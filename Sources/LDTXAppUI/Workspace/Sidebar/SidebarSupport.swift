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

    private var candidate: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
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

struct InlineRenameSession: Equatable {
    let originalName: String
    var draft: String
}

struct WorkspaceSidebarSectionHeader: View {
    let title: String
    let accessibilityIdentifier: String
    let isAddEnabled: Bool
    let add: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            SidebarActionButton(
                systemImage: "plus",
                accessibilityLabel: "Add \(title)",
                accessibilityIdentifier: accessibilityIdentifier,
                action: add
            )
            .disabled(!isAddEnabled)
        }
        .frame(maxWidth: .infinity, minHeight: 24)
    }
}

struct SidebarActionButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.secondary.opacity(0.12) : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
        .onHover { isHovered = $0 }
    }
}
