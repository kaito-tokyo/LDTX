// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

public struct WorkspaceSidebar: View {
  let workspaceBundleStore: any WorkspaceBundleStoreProtocol
  @Bindable var workspaceUIStore: WorkspaceUIStore

  public init(
    workspaceBundleStore: any WorkspaceBundleStoreProtocol, workspaceUIStore: WorkspaceUIStore
  ) {
    self.workspaceBundleStore = workspaceBundleStore
    self.workspaceUIStore = workspaceUIStore
  }

  public var body: some View {
    let inputDevices = workspaceBundleStore.definition.inputDevices
    let videoComponents = workspaceBundleStore.definition.videoComponents
    let visions = workspaceBundleStore.definition.visions

    VStack {
      Button {
        workspaceUIStore.selectedItem = .videoLayers
      } label: {
        Label("Video Layers", systemImage: "square.stack.3d.up")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background {
        if workspaceUIStore.selectedItem == .videoLayers {
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor)
        }
      }

      List(selection: $workspaceUIStore.selectedItem) {
        Section {
          Label("Canvas", systemImage: "rectangle.on.rectangle")
            .tag(WorkspaceSidebarItem.canvas)
          Label("Output", systemImage: "dot.radiowaves.left.and.right")
            .tag(WorkspaceSidebarItem.output)
        } header: {
          Text("WORKSPACE")
        }

        Section {
          ForEach(inputDevices) { device in
            Label(inputDeviceName(device), systemImage: inputDeviceSymbol(device))
              .tag(WorkspaceSidebarItem.inputDevice(device))
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
            Label(videoComponentName(component), systemImage: videoComponentSymbol(component))
              .tag(WorkspaceSidebarItem.videoComponent(component))
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
            Label(visionName(vision), systemImage: "eye")
              .tag(WorkspaceSidebarItem.vision(vision))
          }
          Button {

          } label: {
            Label("Add vision...", systemImage: "plus")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.bordered)
        } header: {
          Text("VISIONS")
        }
      }
    }
    .listStyle(.sidebar)
  }

  private func inputDeviceName(
    _ input: Ldtx_Workspace_V4_InputDeviceWrapper
  ) -> String {
    switch input.definition {
    case .videoDevice(let device): device.displayName
    case .audioDevice(let device): device.displayName
    case nil: "Invalid Input Device"
    }
  }

  private func inputDeviceSymbol(
    _ input: Ldtx_Workspace_V4_InputDeviceWrapper
  ) -> String {
    switch input.definition {
    case .videoDevice: "video"
    case .audioDevice: "waveform"
    case nil: "questionmark.square.dashed"
    }
  }

  private func videoComponentName(
    _ component: Ldtx_Workspace_V4_VideoComponentWrapper
  ) -> String {
    switch component.definition {
    case .vfxSource(let value): value.displayName
    case .solidColorFill(let value): value.displayName
    case .linearGradientFill(let value): value.displayName
    case .radialGradientFill(let value): value.displayName
    case .conicGradientFill(let value): value.displayName
    case .clock(let value): value.displayName
    case .testPattern(let value): value.displayName
    case nil: "Invalid Video Component"
    }
  }

  private func videoComponentSymbol(
    _ component: Ldtx_Workspace_V4_VideoComponentWrapper
  ) -> String {
    switch component.definition {
    case .vfxSource: "play.rectangle"
    case .solidColorFill, .linearGradientFill, .radialGradientFill, .conicGradientFill:
      "paintpalette"
    case .clock: "clock"
    case .testPattern: "testtube.2"
    case nil: "questionmark.square.dashed"
    }
  }

  private func visionName(_ vision: Ldtx_Workspace_V4_VisionWrapper) -> String {
    switch vision.definition {
    case .ocrVision(let value): value.displayName
    case nil: "Invalid Vision"
    }
  }
}

#Preview("Workspace Sidebar") {
  WorkspaceSidebar(
    workspaceBundleStore: PreviewWorkspaceBundleStore(),
    workspaceUIStore: WorkspaceUIStore()
  )
  .frame(width: 260, height: 640)
}
