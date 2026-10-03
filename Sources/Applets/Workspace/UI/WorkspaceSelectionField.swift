// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct WorkspaceSelectionOption<ID: Hashable>: Identifiable {
  let id: ID
  let name: String
}

enum WorkspaceSelectionRules {
  static func canSubmit<ID: Hashable>(
    _ selection: ID?, availableIDs: [ID], isEditable: Bool, loadError: String?
  ) -> Bool {
    guard isEditable else { return false }
    guard let selection else { return true }
    return loadError == nil && availableIDs.contains(selection)
  }

  static func reconciled<ID: Hashable>(_ selection: ID?, availableIDs: [ID]) -> ID? {
    selection.flatMap { availableIDs.contains($0) ? $0 : nil }
  }

  static func displayName<ID: Hashable>(
    selection: ID?, options: [WorkspaceSelectionOption<ID>], loaded: Bool,
    emptyLabel: String = "Unassigned"
  ) -> String {
    guard let selection else { return emptyLabel }
    guard loaded else { return "Checking…" }
    return options.first { $0.id == selection }?.name ?? "Unavailable"
  }
}

/// The model is read for display only; every editing session starts unselected.
struct WorkspaceSelectionField<ID: Hashable>: View {
  let title: String
  let current: ID?
  let options: [WorkspaceSelectionOption<ID>]
  var loaded = true
  var loadError: String? = nil
  var emptyLabel = "Unassigned"
  var clearTitle: String? = nil
  var isEditable = true
  var refresh: () -> Void = {}
  let commit: (ID?) throws -> Void
  @State private var showingSheet = false

  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 8) {
        Text(
          WorkspaceSelectionRules.displayName(
            selection: current, options: options, loaded: loaded, emptyLabel: emptyLabel))
        Button("Change…") {
          refresh()
          showingSheet = true
        }
        .disabled(!isEditable)
        .accessibilityLabel("Change \(title)")
      }
    }
    .sheet(isPresented: $showingSheet) {
      WorkspaceSelectionSheet(
        title: title, options: options, loadError: loadError,
        clearTitle: clearTitle, isEditable: isEditable, refresh: refresh,
        commit: commit, cancel: { showingSheet = false })
    }
  }
}

struct WorkspaceSelectionSheet<ID: Hashable>: View {
  let title: String
  let options: [WorkspaceSelectionOption<ID>]
  let loadError: String?
  let clearTitle: String?
  let isEditable: Bool
  let refresh: () -> Void
  let commit: (ID?) throws -> Void
  let cancel: () -> Void
  var currentDescription: String? = nil
  @State private var selection: ID? = nil
  @State private var failure: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.title2)
      if let currentDescription { Text(currentDescription).foregroundStyle(.secondary) }
      ScrollView {
        VStack(alignment: .leading) {
          ForEach(options) { option in
            Button {
              selection = option.id
              failure = nil
            } label: {
              HStack {
                Text(option.name)
                Spacer()
                if selection == option.id { Image(systemName: "checkmark") }
              }
              .padding(8)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == option.id ? [.isSelected] : [])
          }
          if options.isEmpty { Text("No available options").foregroundStyle(.secondary) }
        }
      }.frame(height: 220)
      if let message = failure ?? loadError { Text(message).foregroundStyle(.red) }
      HStack {
        Button("Refresh", action: refresh)
        if let clearTitle {
          Button(clearTitle) { submit(nil) }.disabled(!isEditable)
        }
        Spacer()
        Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
        Button("Apply") { submit(selection) }
          .keyboardShortcut(.defaultAction)
          .disabled(
            selection == nil
              || !WorkspaceSelectionRules.canSubmit(
                selection, availableIDs: options.map(\.id), isEditable: isEditable,
                loadError: loadError)
          )
      }
    }
    .padding(24).frame(width: 440)
    .onChange(of: options.map(\.id)) { _, ids in
      selection = WorkspaceSelectionRules.reconciled(selection, availableIDs: ids)
    }
  }

  private func submit(_ proposed: ID?) {
    guard isEditable else { return }
    guard proposed == nil || loadError == nil else { return }
    guard proposed == nil || options.contains(where: { $0.id == proposed }) else {
      selection = nil
      failure = "Select an available option."
      return
    }
    do {
      try commit(proposed)
      cancel()
    } catch { failure = error.localizedDescription }
  }
}

struct WorkspaceSelectionError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
