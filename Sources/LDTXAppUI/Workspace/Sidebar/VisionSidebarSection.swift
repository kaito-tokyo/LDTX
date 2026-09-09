// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import SwiftUI

struct VisionSidebarSection: View {
  @Binding var visions: [WorkspaceVisionDefinition]
  @Binding var selectedSidebarItem: WorkspaceSidebarItem?
  let inputDevices: [WorkspaceInputDeviceRecord]
  let videoComponents: [WorkspaceVideoComponentRecord]
  let featureAvailability: WorkspaceFeatureAvailability
  let windowState: WorkspaceWindowState
  @State private var isShowingAddDialog = false
  @State private var proposedName = ""

  var body: some View {
    Section {
      ForEach(visions) { vision in
        VisionSidebarRow(
          vision: vision,
          isEnabled: isVisionConfigurationEditable,
          select: { selectedSidebarItem = .vision(vision.name) }
        )
        .tag(WorkspaceSidebarItem.vision(vision.name))
      }
    } header: {
      WorkspaceSidebarSectionHeader(
        title: "Visions",
        accessibilityIdentifier: "addWorkspaceVisionButton",
        isAddEnabled: isVisionConfigurationEditable,
        add: beginAddingVision
      )
    }
    .sheet(isPresented: $isShowingAddDialog) {
      AddVisionDialog(
        name: $proposedName,
        isNameAvailable: nameIsAvailable,
        submit: addVision(named:),
        cancel: { isShowingAddDialog = false }
      )
    }
  }

  private func beginAddingVision() {
    proposedName = WorkspaceResourceNameValidator.uniqueName(
      base: "Vision", inputDevices: inputDevices, videoComponents: videoComponents,
      visions: visions
    )
    isShowingAddDialog = true
  }

  /// Vision observes or parameterizes the render pipeline; it does not
  /// rebuild that pipeline, so Output mode intentionally leaves it editable.
  private var isVisionConfigurationEditable: Bool {
    featureAvailability.supportsVision
      && !windowState.isOperationLocked
  }

  private func nameIsAvailable(_ name: String) -> Bool {
    WorkspaceResourceNameValidator.isAvailable(
      name, inputDevices: inputDevices, videoComponents: videoComponents,
      visions: visions
    )
  }

  private func addVision(named name: String) {
    guard nameIsAvailable(name) else { return }
    visions.append(WorkspaceVisionDefinition(name: name))
    selectedSidebarItem = .vision(name)
    isShowingAddDialog = false
  }
}

private struct AddVisionDialog: View {
  @Binding var name: String
  let isNameAvailable: (String) -> Bool
  let submit: (String) -> Void
  let cancel: () -> Void
  @FocusState private var isNameFieldFocused: Bool

  private var candidate: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var canSubmit: Bool { !candidate.isEmpty && isNameAvailable(candidate) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add Vision").font(.headline)
      TextField("Vision Name", text: $name)
        .focused($isNameFieldFocused)
        .onSubmit { if canSubmit { submit(candidate) } }
      Text("Recognize text locally with Apple Vision.")
        .font(.caption)
        .foregroundStyle(.secondary)
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
    .frame(width: 420)
    .onAppear { isNameFieldFocused = true }
  }
}

private struct VisionSidebarRow: View {
  let vision: WorkspaceVisionDefinition
  let isEnabled: Bool
  let select: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "eye").foregroundStyle(.secondary).frame(width: 16)
      Text(vision.name).lineLimit(1)
      Spacer(minLength: 8)
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: select)
    // A row is not a Button, so disabled alone does not reliably suppress
    // its gesture. This is UI admission control only; it never cancels
    // Vision work already submitted to the background queue.
    .disabled(!isEnabled)
    .allowsHitTesting(isEnabled)
  }
}
