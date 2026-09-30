// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

public struct WorkspaceSidebar: View {
  @Bindable var uiState: WorkspaceUIState

  public init(uiState: WorkspaceUIState) {
    self._uiState = Bindable(wrappedValue: uiState)
  }

  public var body: some View {
    let inputDevices = uiState.definition.inputDevices
    let videoComponents = uiState.definition.videoComponents
    let visions = uiState.definition.visions

    VStack {
      Button {
        uiState.inspectorSelector = .init(kind: .programVideoLayers)
      } label: {
        Label("Video Layers", systemImage: "square.stack.3d.up")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background {
        if uiState.inspectorSelector?.kind == .programVideoLayers {
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor)
        }
      }

      List(selection: $uiState.inspectorSelector) {
        Section {
          Label("Canvas", systemImage: "rectangle.on.rectangle")
            .tag(WorkspaceInspectorSelector(kind: .workspaceCanvas))
          Label("Output", systemImage: "dot.radiowaves.left.and.right")
            .tag(WorkspaceInspectorSelector(kind: .workspaceOutput))
        } header: {
          Text("WORKSPACE")
        }

        Section {
          ForEach(inputDevices) { device in
            switch device.definition {
            case .audioDevice(let audioDevice):
              Label(audioDevice.displayName, systemImage: "waveform")
                .tag(WorkspaceInspectorSelector(
                  kind: .audioInputDevice, internalID: audioDevice.internalID))
            case .videoDevice(let videoDevice):
              Label(videoDevice.displayName, systemImage: "video")
                .tag(WorkspaceInspectorSelector(
                  kind: .videoInputDevice, internalID: videoDevice.internalID))
            case nil:
              Label("(invalid)", systemImage: "questionmark.square.dashed")
            }
          }

          Button {

          } label: {
            Label("Add device...", systemImage: "plus")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } header: {
          Text("INPUT DEVICES")
        }

        Section {
          ForEach(videoComponents) { component in
            switch component.definition {
            case .vfxSource(let source):
              Label(source.displayName, systemImage: "play.rectangle")
                .tag(WorkspaceInspectorSelector(
                  kind: .vfxVideoComponent, internalID: source.internalID))
            case .solidColorFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(WorkspaceInspectorSelector(
                  kind: .solidColorFillVideoComponent, internalID: fill.internalID))
            case .linearGradientFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(WorkspaceInspectorSelector(
                  kind: .linearGradientFillVideoComponent, internalID: fill.internalID))
            case .radialGradientFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(WorkspaceInspectorSelector(
                  kind: .radialGradientFillVideoComponent, internalID: fill.internalID))
            case .conicGradientFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(WorkspaceInspectorSelector(
                  kind: .conicGradientFillVideoComponent, internalID: fill.internalID))
            case .clock(let clock):
              Label(clock.displayName, systemImage: "clock")
                .tag(WorkspaceInspectorSelector(
                  kind: .clockVideoComponent, internalID: clock.internalID))
            case .testPattern(let testPattern):
              Label(testPattern.displayName, systemImage: "testtube.2")
                .tag(WorkspaceInspectorSelector(
                  kind: .testPatternVideoComponent, internalID: testPattern.internalID))
            case nil:
              Label("(invalid)", systemImage: "questionmark.square.dashed")
            }
          }

          Button {

          } label: {
            Label("Add video component...", systemImage: "plus")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } header: {
          Text("VIDEO COMPONENTS")
        }

        Section {
          ForEach(visions) { vision in
            switch vision.definition {
            case .ocrVision(let ocrVision):
              Label(ocrVision.displayName, systemImage: "eye")
                .tag(WorkspaceInspectorSelector(
                  kind: .ocrVision, internalID: ocrVision.internalID))
            case nil:
              Label("(invalid)", systemImage: "questionmark.square.dashed")
            }
          }

          Button {

          } label: {
            Label("Add vision...", systemImage: "plus")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } header: {
          Text("VISIONS")
        }
      }
    }
    .listStyle(.sidebar)
  }

}

#Preview("Workspace Sidebar") {
  @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState()
  WorkspaceSidebar(uiState: uiState)
    .frame(width: 260, height: 640)
}
