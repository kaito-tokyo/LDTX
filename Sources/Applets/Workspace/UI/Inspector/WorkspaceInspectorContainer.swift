// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import SwiftUI

#if DEBUG
  import AppKit
#endif

public struct WorkspaceInspectorContainer: View {
  @Environment(\.documentReference) private var documentReference
  private var workspaceURL: URL? {
    guard let document = documentReference?.document else { return nil }
    return document.fileURL ?? uiState.localStateURL
  }
  let deviceRegistry: DeviceRegistryService
  @Bindable var appletData: WorkspaceAppletData
  @Bindable var uiState: WorkspaceUIState

  public init(
    deviceRegistry: DeviceRegistryService,
    uiState: WorkspaceUIState,
    appletData: WorkspaceAppletData
  ) {
    self.deviceRegistry = deviceRegistry
    self._appletData = Bindable(wrappedValue: appletData)
    self._uiState = Bindable(wrappedValue: uiState)
  }

  public var body: some View {
    if let selector = uiState.inspectorSelector {
      inspector(for: selector)
        .id(selector)
    } else {
      emptyInspector
    }
  }

  @ViewBuilder
  private func inspector(for selector: WorkspaceInspectorSelector) -> some View {
    switch selector.kind {
    case .invalid:
      emptyInspector
    case .programVideoLayers:
      ProgramVideoLayersInspector(
        uiState: uiState,
        appletData: appletData)
    case .workspaceCanvas:
      WorkspaceCanvasInspector(uiState: uiState)
    case .workspaceOutput:
      if workspaceURL != nil {
        WorkspaceOutputInspector(
          uiState: uiState, appletData: appletData)
      } else {
        unavailablePreviewInspector
      }
    case .audioInputDevice:
      if let internalID = selector.internalID {
        AudioInputDeviceInspector(
          uiState: uiState, internalID: internalID,
          deviceRegistry: deviceRegistry,
          appletData: appletData)
      } else {
        emptyInspector
      }
    case .videoInputDevice:
      if let internalID = selector.internalID {
        VideoInputDeviceInspector(
          uiState: uiState, internalID: internalID,
          deviceRegistry: deviceRegistry,
          appletData: appletData)
      } else {
        emptyInspector
      }
    case .vfxVideoComponent:
      if let internalID = selector.internalID {
        VfxVideoComponentInspector(
          uiState: uiState, internalID: internalID)
      } else {
        emptyInspector
      }
    case .solidColorFillVideoComponent:
      if let internalID = selector.internalID {
        SolidColorFillVideoComponentInspector(
          uiState: uiState,
          videoComponentID: .solidColorFill(internalID))
      } else {
        emptyInspector
      }
    case .linearGradientFillVideoComponent:
      if let internalID = selector.internalID {
        LinearGradientFillVideoComponentInspector(
          uiState: uiState,
          videoComponentID: .linearGradientFill(internalID))
      } else {
        emptyInspector
      }
    case .radialGradientFillVideoComponent:
      if let internalID = selector.internalID {
        RadialGradientFillVideoComponentInspector(
          uiState: uiState,
          videoComponentID: .radialGradientFill(internalID))
      } else {
        emptyInspector
      }
    case .conicGradientFillVideoComponent:
      if let internalID = selector.internalID {
        ConicGradientFillVideoComponentInspector(
          uiState: uiState,
          videoComponentID: .conicGradientFill(internalID))
      } else {
        emptyInspector
      }
    case .clockVideoComponent:
      if let internalID = selector.internalID {
        ClockInspector(
          uiState: uiState, internalID: internalID)
      } else {
        emptyInspector
      }
    case .testPatternVideoComponent:
      if let internalID = selector.internalID {
        TestPatternInspector(
          uiState: uiState, internalID: internalID)
      } else {
        emptyInspector
      }
    case .ocrVision:
      if let internalID = selector.internalID {
        OcrVisionInspector(
          uiState: uiState, internalID: internalID)
      } else {
        emptyInspector
      }
    }
  }

  private var emptyInspector: some View {
    Text("Select a Workspace item to inspect it.")
      .foregroundStyle(.secondary)
  }

  private var unavailablePreviewInspector: some View {
    Text("This Inspector requires a Workspace URL.")
      .foregroundStyle(.secondary)
  }

}

#if DEBUG
  #Preview("Workspace Inspector — Sidebar") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .solidColorFillVideoComponent, internalID: 4))

    HStack(spacing: 0) {
      WorkspaceSidebar(
        uiState: uiState
      )
      .frame(width: 230)

      Divider()

      WorkspaceInspectorContainer(
        deviceRegistry: DeviceRegistryService(), uiState: uiState, appletData: WorkspaceAppletData()
      )
      .padding(16)
      .frame(width: 260)
      .frame(maxHeight: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 520, minHeight: 640)
  }
#endif
