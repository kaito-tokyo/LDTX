// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

public struct WorkspaceSidebarPane: View {
  @Binding private var selectedSidebarItem: WorkspaceSidebarItem?
  @Binding private var inputDevices: [WorkspaceInputDeviceRecord]
  @Binding private var preferences: ProgramPreferences
  @Binding private var visions: [WorkspaceVisionDefinition]
  @Binding private var videoComponents: [WorkspaceVideoComponentRecord]
  private let windowState: WorkspaceWindowState
  private let featureAvailability: WorkspaceFeatureAvailability
  private let cameras: [InputPhysicalDeviceOption]
  private let audioDevices: [InputPhysicalDeviceOption]

  public init(
    selectedSidebarItem: Binding<WorkspaceSidebarItem?>,
    workspaceInputDevices: Binding<[WorkspaceInputDeviceRecord]>,
    programPreferences: Binding<ProgramPreferences>,
    visions: Binding<[WorkspaceVisionDefinition]>,
    videoComponents: Binding<[WorkspaceVideoComponentRecord]> = .constant([]),
    windowState: WorkspaceWindowState = WorkspaceWindowState(
      mode: .edit,
      outputSessionState: .idle,
      isOperationLocked: false
    ),
    featureAvailability: WorkspaceFeatureAvailability = .all,
    cameras: [InputPhysicalDeviceOption] = [],
    audioDevices: [InputPhysicalDeviceOption] = []
  ) {
    _selectedSidebarItem = selectedSidebarItem
    _inputDevices = workspaceInputDevices
    _preferences = programPreferences
    _visions = visions
    _videoComponents = videoComponents
    self.windowState = windowState
    self.featureAvailability = featureAvailability
    self.cameras = cameras
    self.audioDevices = audioDevices
  }

  public var body: some View {
    VStack(spacing: 0) {
      List(selection: $selectedSidebarItem) {
        Label("Video Layers", systemImage: "square.stack.3d.up")
          .foregroundStyle(.primary).tag(WorkspaceSidebarItem.videoLayers)
        Label("Canvas", systemImage: "rectangle.on.rectangle")
          .foregroundStyle(.primary).tag(WorkspaceSidebarItem.canvas)
        Label("Output", systemImage: "dot.radiowaves.left.and.right")
          .foregroundStyle(.primary).tag(WorkspaceSidebarItem.output)
        InputDevicesSidebarSection(
          inputDevices: $inputDevices, preferences: $preferences,
          selectedSidebarItem: $selectedSidebarItem, visions: visions,
          videoComponents: videoComponents,
          cameras: cameras, audioDevices: audioDevices,
          windowState: windowState
        )
        VideoComponentsSidebarSection(
          videoComponents: $videoComponents,
          selectedSidebarItem: $selectedSidebarItem,
          inputDevices: inputDevices,
          visions: visions,
          windowState: windowState
        )
        VisionSidebarSection(
          visions: $visions, selectedSidebarItem: $selectedSidebarItem,
          inputDevices: inputDevices, videoComponents: videoComponents,
          featureAvailability: featureAvailability,
          windowState: windowState
        )
      }
      .listStyle(.sidebar)

      Divider()
      Button {
        selectedSidebarItem = .programs
      } label: {
        HStack {
          Label("Programs", systemImage: "list.bullet.rectangle")
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .background(selectedSidebarItem == .programs ? Color.accentColor.opacity(0.18) : .clear)
      .disabled(windowState.mode == .output || windowState.isOperationLocked)
      .accessibilityIdentifier("manageProgramsButton")
    }
    .navigationTitle("Workspace")
  }

}
