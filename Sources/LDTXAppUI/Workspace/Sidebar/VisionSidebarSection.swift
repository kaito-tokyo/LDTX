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
  @State private var proposedKind: ProposedVisionKind = .visionLanguageModel

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
        kind: $proposedKind,
        isNameAvailable: nameIsAvailable,
        submit: addVision(named:kind:),
        cancel: { isShowingAddDialog = false }
      )
    }
  }

  private func beginAddingVision() {
    proposedName = WorkspaceResourceNameValidator.uniqueName(
      base: "Vision", inputDevices: inputDevices, videoComponents: videoComponents,
      visions: visions
    )
    proposedKind = .visionLanguageModel
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

  private func addVision(named name: String, kind: ProposedVisionKind) {
    guard nameIsAvailable(name) else { return }
    var vision = WorkspaceVisionDefinition(name: name)
    if kind == .opticalCharacterRecognition {
      vision.definition = .opticalCharacterRecognition(.init())
    }
    visions.append(vision)
    selectedSidebarItem = .vision(name)
    isShowingAddDialog = false
  }
}

private enum ProposedVisionKind: String, CaseIterable, Identifiable {
  case visionLanguageModel
  case opticalCharacterRecognition

  var id: Self { self }
  var title: String {
    switch self {
    case .visionLanguageModel: "VLM"
    case .opticalCharacterRecognition: "OCR"
    }
  }
  var description: String {
    switch self {
    case .visionLanguageModel: "Analyze images with a vision language model."
    case .opticalCharacterRecognition: "Recognize text locally with Apple Vision."
    }
  }
}

private struct AddVisionDialog: View {
  @Binding var name: String
  @Binding var kind: ProposedVisionKind
  let isNameAvailable: (String) -> Bool
  let submit: (String, ProposedVisionKind) -> Void
  let cancel: () -> Void
  @FocusState private var isNameFieldFocused: Bool

  private var candidate: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var canSubmit: Bool { !candidate.isEmpty && isNameAvailable(candidate) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add Vision").font(.headline)
      TextField("Vision Name", text: $name)
        .focused($isNameFieldFocused)
        .onSubmit { if canSubmit { submit(candidate, kind) } }
      Picker("Vision Type", selection: $kind) {
        ForEach(ProposedVisionKind.allCases) { kind in
          Text(kind.title).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      Text(kind.description)
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
        Button("Add") { submit(candidate, kind) }
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
