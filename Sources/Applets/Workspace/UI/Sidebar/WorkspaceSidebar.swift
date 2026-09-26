// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

public struct WorkspaceSidebar: View {
  let workspaceBundleStore: any WorkspaceBundleStoreProtocol
  @Bindable var uiState: WorkspaceUIState

  public init(
    workspaceBundleStore: any WorkspaceBundleStoreProtocol,
    uiState: WorkspaceUIState
  ) {
    self.workspaceBundleStore = workspaceBundleStore
    self._uiState = Bindable(wrappedValue: uiState)
  }

  public var body: some View {
    let inputDevices = uiState.definition.inputDevices
    let videoComponents = uiState.definition.videoComponents
    let visions = uiState.definition.visions

    VStack {
      Button {
        uiState.inspectorKind = .programVideoLayers
      } label: {
        Label("Video Layers", systemImage: "square.stack.3d.up")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background {
        if uiState.inspectorKind == .programVideoLayers {
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor)
        }
      }

      List(selection: $uiState.inspectorKind) {
        Section {
          Label("Canvas", systemImage: "rectangle.on.rectangle")
            .tag(WorkspaceInspectorKind.workspaceCanvas)
          Label("Output", systemImage: "dot.radiowaves.left.and.right")
            .tag(WorkspaceInspectorKind.workspaceOutput)
        } header: {
          Text("WORKSPACE")
        }

        Section {
          ForEach(inputDevices) { device in
            switch device.definition {
            case .audioDevice(let audioDevice):
              Label(audioDevice.displayName, systemImage: "waveform")
                .tag(WorkspaceInspectorKind.audioInputDevice(audioDevice.internalID))
            case .videoDevice(let videoDevice):
              Label(videoDevice.displayName, systemImage: "video")
                .tag(WorkspaceInspectorKind.videoInputDevice(videoDevice.internalID))
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
                .tag(WorkspaceInspectorKind.vfxVideoComponent(source.internalID))
            case .solidColorFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(WorkspaceInspectorKind.solidColorFillVideoComponent(fill.internalID))
            case .linearGradientFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(WorkspaceInspectorKind.linearGradientFillVideoComponent(fill.internalID))
            case .radialGradientFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(WorkspaceInspectorKind.radialGradientFillVideoComponent(fill.internalID))
            case .conicGradientFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(WorkspaceInspectorKind.conicGradientFillVideoComponent(fill.internalID))
            case .clock(let clock):
              Label(clock.displayName, systemImage: "clock")
                .tag(WorkspaceInspectorKind.clockVideoComponent(clock.internalID))
            case .testPattern(let testPattern):
              Label(testPattern.displayName, systemImage: "testtube.2")
                .tag(WorkspaceInspectorKind.testPatternVideoComponent(testPattern.internalID))
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
                .tag(WorkspaceInspectorKind.ocrVision(ocrVision.internalID))
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
  WorkspaceSidebar(
    workspaceBundleStore: NullWorkspaceBundleStore(),
    uiState: uiState
  )
  .frame(width: 260, height: 640)
}
