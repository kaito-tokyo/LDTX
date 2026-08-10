// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

struct WorkspaceVideoComponentDetailPane: View {
  @Binding var videoComponents: [WorkspaceVideoComponentRecord]
  @Binding var selectedSidebarItem: WorkspaceSidebarItem?
  let workspaceInputDevices: [WorkspaceInputDeviceRecord]
  let deleteVideoComponent: (String) -> Void
  var isStructureEditable = true
  var supportsBackgroundRemoval = true

  var body: some View {
    Form {
      if let component = selectedComponentBinding {
        Section("Video Component") {
          LabeledContent("Name", value: component.wrappedValue.name)
          LabeledContent("Kind", value: component.wrappedValue.component.definition.displayName)
          if component.wrappedValue.component.definition.usesInputCameraDevice {
            Picker("Input Device", selection: component.inputDeviceID) {
              Text("None").tag(String?.none)
              ForEach(workspaceInputDevices.filter { $0.kind == .video }) { device in
                Text(device.name).tag(Optional(device.id))
              }
            }
            Toggle("Background Removal", isOn: component.removesBackground)
              .disabled(!supportsBackgroundRemoval)
            if !supportsBackgroundRemoval {
              Text("Background removal is unavailable in this app target.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        if component.wrappedValue.component.definition.usesInputCameraDevice {
          Section("Crop") {
            cropField(
              "Top", value: component.sourceCropTop,
              accessibilityIdentifier: "videoComponentCropTopField")
            cropField(
              "Right", value: component.sourceCropRight,
              accessibilityIdentifier: "videoComponentCropRightField")
            cropField(
              "Bottom", value: component.sourceCropBottom,
              accessibilityIdentifier: "videoComponentCropBottomField")
            cropField(
              "Left", value: component.sourceCropLeft,
              accessibilityIdentifier: "videoComponentCropLeftField")
          }
        } else if let componentStepBinding {
          Section("Appearance") {
            ProgramComponentEditor(
              step: componentStepBinding,
              workspaceInputDevices: workspaceInputDevices,
              showsComponentPicker: false
            )
          }
        }
        Section {
          Button("Delete Video Component", role: .destructive, action: deleteSelectedComponent)
            .disabled(!isStructureEditable)
        }
      } else {
        ContentUnavailableView("Select a Video Component", systemImage: "play.rectangle")
      }
    }
    .formStyle(.grouped)
  }

  private var selectedComponentBinding: Binding<WorkspaceVideoComponentRecord>? {
    guard case .videoComponent(let id) = selectedSidebarItem,
      let index = videoComponents.firstIndex(where: { $0.id == id })
    else { return nil }
    return $videoComponents[index]
  }

  private var componentStepBinding: Binding<CompositeProgramStep>? {
    guard let component = selectedComponentBinding else { return nil }
    return Binding(
      get: {
        CompositeProgramStep(
          displayName: component.wrappedValue.name, component: component.wrappedValue.component)
      },
      set: { step in component.wrappedValue.component = step.component }
    )
  }

  private func cropField(
    _ label: String,
    value: Binding<Float>,
    accessibilityIdentifier: String
  ) -> some View {
    LabeledContent(label) {
      HStack(spacing: 6) {
        TextField(label, value: value, format: .number)
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 72)
          .accessibilityLabel(label)
          .accessibilityIdentifier(accessibilityIdentifier)
        Text("%")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func deleteSelectedComponent() {
    guard case .videoComponent(let id) = selectedSidebarItem else { return }
    deleteVideoComponent(id)
  }
}
