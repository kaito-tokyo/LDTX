// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

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
