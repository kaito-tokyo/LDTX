// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

public struct WorkspaceSidebar: View {
  let workspaceBundleStore: any WorkspaceBundleStoreProtocol
  @State private var inspectorKind: WorkspaceInspectorKind = .none

  public init(workspaceBundleStore: any WorkspaceBundleStoreProtocol) {
    self.workspaceBundleStore = workspaceBundleStore
  }

  public var body: some View {
    let inputDevices = workspaceBundleStore.definition.inputDevices
    let videoComponents = workspaceBundleStore.definition.videoComponents
    let visions = workspaceBundleStore.definition.visions
    let selection = Binding<WorkspaceInspectorKind?>(
      get: { inspectorKind == .none ? nil : inspectorKind },
      set: { inspectorKind = $0 ?? .none }
    )

    VStack {
      Button {
        inspectorKind = .videoLayers
      } label: {
        Label("Video Layers", systemImage: "square.stack.3d.up")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background {
        if inspectorKind == .videoLayers {
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor)
        }
      }

      List(selection: selection) {
        Section {
          Label("Canvas", systemImage: "rectangle.on.rectangle")
            .tag(WorkspaceInspectorKind.canvas)
          Label("Output", systemImage: "dot.radiowaves.left.and.right")
            .tag(WorkspaceInspectorKind.output)
        } header: {
          Text("WORKSPACE")
        }

        Section {
          ForEach(inputDevices) { device in
            switch device.definition {
            case .audioDevice(let audioDevice):
              Label(audioDevice.displayName, systemImage: "waveform")
                .tag(WorkspaceInspectorKind.inputDevice(audioDevice.internalID))
            case .videoDevice(let videoDevice):
              Label(videoDevice.displayName, systemImage: "video")
                .tag(WorkspaceInspectorKind.inputDevice(videoDevice.internalID))
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
                .tag(WorkspaceInspectorKind.videoComponent(source.internalID))
            case .solidColorFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(WorkspaceInspectorKind.videoComponent(fill.internalID))
            case .linearGradientFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(WorkspaceInspectorKind.videoComponent(fill.internalID))
            case .radialGradientFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(WorkspaceInspectorKind.videoComponent(fill.internalID))
            case .conicGradientFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(WorkspaceInspectorKind.videoComponent(fill.internalID))
            case .clock(let clock):
              Label(clock.displayName, systemImage: "clock")
                .tag(WorkspaceInspectorKind.videoComponent(clock.internalID))
            case .testPattern(let testPattern):
              Label(testPattern.displayName, systemImage: "testtube.2")
                .tag(WorkspaceInspectorKind.videoComponent(testPattern.internalID))
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
                .tag(WorkspaceInspectorKind.vision(ocrVision.internalID))
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
  WorkspaceSidebar(
    workspaceBundleStore: PreviewWorkspaceBundleStore()
  )
  .frame(width: 260, height: 640)
}
