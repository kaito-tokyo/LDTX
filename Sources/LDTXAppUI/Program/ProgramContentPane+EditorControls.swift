// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

struct VideoLayersDetailPane: View {
  var selectedProgramDefinitionName: String?
  var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
  @Binding var compositeProgramDefinition: CompositeProgramDefinition
  @Binding var programPreferences: ProgramPreferences
  var workspaceInputDevices: [WorkspaceInputDeviceRecord]
  var workspaceVideoComponents: [WorkspaceVideoComponentRecord]
  var windowState: WorkspaceWindowState

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Video Layers")
        .font(.headline)
        .padding(.horizontal, 20)
        .padding(.top, 16)
      Form {
        videoComponentControls
      }
      .formStyle(.grouped)
    }
  }

  private var videoComponentControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      if videoLayers.isEmpty {
        Text("No video layers")
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 8) {
          ForEach(Array(videoLayers.enumerated()), id: \.element.id) { index, layer in
            videoLayerRow(for: layer, index: index)
          }
        }
      }

      Menu {
        if !availableVideoInputDevices.isEmpty {
          Section("Video Input Devices") {
            ForEach(availableVideoInputDevices) { device in
              Button(device.name) {
                addVideoInputDevice(device)
              }
            }
          }
        }
        if !availableWorkspaceVideoComponents.isEmpty {
          Section("Video Components") {
            ForEach(availableWorkspaceVideoComponents) { component in
              Button(component.name) {
                addWorkspaceVideoComponent(component)
              }
            }
          }
        }
      } label: {
        Label("Add Video Layer", systemImage: "plus")
      }
      .disabled(
        !isProgramStructureEditable
          || (availableWorkspaceVideoComponents.isEmpty && availableVideoInputDevices.isEmpty)
      )
      .accessibilityLabel("Add Video Layer")
      .accessibilityIdentifier("addProgramComponentButton")

      if workspaceVideoComponents.isEmpty {
        Text("Create a Video Component in the sidebar first.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if availableWorkspaceVideoComponents.isEmpty && availableVideoInputDevices.isEmpty {
        Text("All available Video Inputs and Video Components already have a Video Layer.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func videoLayerRow(
    for layer: VideoLayerPreference,
    index: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button {
          setVideoLayerMuted(!layer.isMuted, at: index)
        } label: {
          Image(systemName: videoLayerSystemImage(named: layer.componentName))
        }
        .buttonStyle(.borderless)
        .help(layer.isMuted ? "Unmute Video Layer" : "Mute Video Layer")
        .accessibilityLabel(layer.isMuted ? "Unmute Video Layer" : "Mute Video Layer")
        .accessibilityValue(layer.isMuted ? "Muted" : "Unmuted")

        Text(layer.componentName)
          .lineLimit(1)
          .strikethrough(layer.isMuted)

        Spacer(minLength: 8)

        Button {
          moveCompositeStep(index: index, offset: -1)
        } label: {
          Label("Move Up", systemImage: "arrow.up")
        }
        .labelStyle(.iconOnly)
        .disabled(!isProgramStructureEditable || !canMoveCompositeStep(index: index, offset: -1))
        .accessibilityIdentifier("moveVideoComponentUpButton-\(layer.id)")

        Button {
          moveCompositeStep(index: index, offset: 1)
        } label: {
          Label("Move Down", systemImage: "arrow.down")
        }
        .labelStyle(.iconOnly)
        .disabled(!isProgramStructureEditable || !canMoveCompositeStep(index: index, offset: 1))
        .accessibilityIdentifier("moveVideoComponentDownButton-\(layer.id)")

        Button(role: .destructive) {
          removeVideoLayer(id: layer.id)
        } label: {
          Label("Remove from Program", systemImage: "minus")
        }
        .labelStyle(.iconOnly)
        .disabled(!isProgramStructureEditable)
        .accessibilityIdentifier("removeVideoComponentButton-\(layer.id)")
      }
      .buttonStyle(.borderless)

      destinationControls(index: index)
    }
    .padding(10)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.background.secondary)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(.separator, lineWidth: 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .opacity(layer.isMuted ? 0.45 : 1)
    .accessibilityIdentifier("videoComponentRow-\(layer.componentName)")
  }

  @ViewBuilder
  private func destinationControls(index: Int) -> some View {
    if videoLayers.indices.contains(index),
      layerSupportsDestination(videoLayers[index])
    {
      HStack(spacing: 8) {
        Text("X")
        ProgramTableFloatField(
          value: layerDestinationBinding(index: index, keyPath: \.destinationX),
          unit: "px",
          fractionDigits: 0
        )
        Text("Y")
        ProgramTableFloatField(
          value: layerDestinationBinding(index: index, keyPath: \.destinationY),
          unit: "px",
          fractionDigits: 0
        )
        Text("Scale")
        ProgramTableFloatField(
          value: layerDestinationBinding(index: index, keyPath: \.destinationScale),
          unit: "x",
          fractionDigits: 2
        )
        Spacer(minLength: 0)
      }
      .font(.callout)
    }
  }

  private func layerDestinationBinding(
    index: Int,
    keyPath: WritableKeyPath<VideoLayerPreference, Float>
  ) -> Binding<Float> {
    Binding(
      get: { videoLayers[index][keyPath: keyPath] },
      set: { value in
        updateVideoLayers { $0[index][keyPath: keyPath] = value }
        applyVideoLayerPreferencesToWorkingComposite()
      }
    )
  }

  private func setVideoLayerMuted(_ muted: Bool, at index: Int) {
    guard videoLayers.indices.contains(index) else { return }
    updateVideoLayers { $0[index].isMuted = muted }
  }

  private var availableWorkspaceVideoComponents: [WorkspaceVideoComponentRecord] {
    let usedNames = Set(videoLayers.map(\.componentName))
    return workspaceVideoComponents.filter { !usedNames.contains($0.name) }
  }

  private var availableVideoInputDevices: [WorkspaceInputDeviceRecord] {
    let usedNames = Set(videoLayers.map(\.componentName))
    return workspaceInputDevices.filter { $0.kind == .video && !usedNames.contains($0.name) }
  }

  private var isProgramStructureEditable: Bool {
    windowState.mode == .edit && !windowState.isOperationLocked
  }

  private func addWorkspaceVideoComponent(_ resource: WorkspaceVideoComponentRecord) {
    guard !videoLayers.contains(where: { $0.componentName == resource.name }) else { return }
    updateVideoLayers { $0.append(VideoLayerPreference(componentName: resource.name)) }
    let step = CompositeProgramStep(
      displayName: resource.name,
      component: resource.component
    )
    compositeProgramDefinition.steps.append(step)
    applyVideoLayerPreferencesToWorkingComposite()
  }

  private func addVideoInputDevice(_ device: WorkspaceInputDeviceRecord) {
    guard !videoLayers.contains(where: { $0.componentName == device.name }) else { return }
    updateVideoLayers { $0.append(VideoLayerPreference(componentName: device.name)) }
    compositeProgramDefinition.steps.append(
      CompositeProgramStep(
        displayName: device.name,
        component: .inputCameraDevice(InputDeviceComponent(inputDeviceID: device.id))
      )
    )
    applyVideoLayerPreferencesToWorkingComposite()
  }

  private func canMoveCompositeStep(index: Int, offset: Int) -> Bool {
    guard videoLayers.indices.contains(index) else { return false }
    return videoLayers.indices.contains(index + offset)
  }

  private func moveCompositeStep(index: Int, offset: Int) {
    guard videoLayers.indices.contains(index) else { return }
    let destination = index + offset
    guard videoLayers.indices.contains(destination) else { return }
    updateVideoLayers { $0.swapAt(index, destination) }
    applyVideoLayerPreferencesToWorkingComposite()
  }

  private func removeVideoLayer(id: String) {
    updateVideoLayers { $0.removeAll { $0.id == id } }
    compositeProgramDefinition.steps.removeAll { $0.id == id }
  }

  private func componentDefinition(named name: String) -> ProgramComponentDefinition? {
    workspaceVideoComponents.first(where: { $0.name == name })?.component.definition
  }

  private func videoLayerSystemImage(named name: String) -> String {
    if workspaceInputDevices.contains(where: { $0.name == name }) {
      return "video"
    }
    return componentDefinition(named: name)?.videoComponentSystemImage ?? "square.stack"
  }

  private func layerSupportsDestination(_ layer: VideoLayerPreference) -> Bool {
    VideoLayerDestinationPolicy.supportsDestination(
      layerName: layer.componentName,
      inputDevices: workspaceInputDevices,
      videoComponents: workspaceVideoComponents
    )
  }

  private func applyVideoLayerPreferencesToWorkingComposite() {
    compositeProgramDefinition = WorkspaceVideoComponentResolver.applying(
      workspaceVideoComponents,
      layers: videoLayers,
      to: compositeProgramDefinition
    )
  }

  private var videoLayerProgramName: String {
    selectedProgramDefinitionName ?? selectedProgramDefinitionRecord?.name ?? "New Program"
  }

  private var videoLayers: [VideoLayerPreference] {
    programPreferences.videoLayers(forProgramNamed: videoLayerProgramName)
  }

  private func updateVideoLayers(_ mutation: (inout [VideoLayerPreference]) -> Void) {
    var layers = videoLayers
    mutation(&layers)
    programPreferences.setVideoLayers(layers, forProgramNamed: videoLayerProgramName)
  }
}

enum VideoLayerDestinationPolicy {
  static func supportsDestination(
    layerName: String,
    inputDevices: [WorkspaceInputDeviceRecord],
    videoComponents: [WorkspaceVideoComponentRecord]
  ) -> Bool {
    if inputDevices.contains(where: { $0.kind == .video && $0.name == layerName }) {
      return true
    }
    return switch videoComponents.first(where: { $0.name == layerName })?.component.definition {
    case .inputCameraDevice, .clock:
      true
    case .fillSolidColor, .fillLinearGradient, .fillRadialGradient, .fillConicGradient,
      .testPattern, .none:
      false
    }
  }
}

extension ProgramComponentDefinition {
  fileprivate var videoComponentSystemImage: String {
    switch self {
    case .inputCameraDevice:
      return "video"
    case .fillSolidColor:
      return "square"
    case .fillLinearGradient:
      return "circle.lefthalf.filled"
    case .fillRadialGradient:
      return "circle.righthalf.filled"
    case .fillConicGradient:
      return "circle.bottomhalf.filled"
    case .clock:
      return "clock"
    case .testPattern:
      return "checkerboard.rectangle"
    }
  }
}
