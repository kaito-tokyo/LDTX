// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

#if DEBUG
  import AppKit
#endif

public struct WorkspaceInspectorContainer: View {
  let windowRuntime: (any WorkspaceWindowRuntimeProtocol)?
  @Bindable var appletData: WorkspaceAppletData
  @Bindable var uiState: WorkspaceUIState

  public init(
    windowRuntime: any WorkspaceWindowRuntimeProtocol,
    uiState: WorkspaceUIState,
    appletData: WorkspaceAppletData
  ) {
    self.windowRuntime = windowRuntime
    self._appletData = Bindable(wrappedValue: appletData)
    self._uiState = Bindable(wrappedValue: uiState)
  }

  init(
    uiState: WorkspaceUIState,
    appletData: WorkspaceAppletData = WorkspaceAppletData()
  ) {
    self.windowRuntime = nil
    self._appletData = Bindable(wrappedValue: appletData)
    self._uiState = Bindable(wrappedValue: uiState)
  }

  public var body: some View {
    if let selector = uiState.inspectorSelector {
      inspector(for: selector)
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
        windowRuntime: windowRuntime)
    case .workspaceCanvas:
      if let windowRuntime {
        WorkspaceCanvasInspector(windowRuntime: windowRuntime, uiState: uiState)
      } else {
        unavailablePreviewInspector
      }
    case .workspaceOutput:
      if let windowRuntime {
        WorkspaceOutputInspector(windowRuntime: windowRuntime, uiState: uiState)
      } else {
        unavailablePreviewInspector
      }
    case .audioInputDevice:
      if let internalID = selector.internalID {
        AudioInputDeviceInspector(
          uiState: uiState, internalID: internalID, windowRuntime: windowRuntime,
          appletData: appletData)
      } else {
        emptyInspector
      }
    case .videoInputDevice:
      if let internalID = selector.internalID {
        VideoInputDeviceInspector(
          uiState: uiState, internalID: internalID, windowRuntime: windowRuntime,
          appletData: appletData)
      } else {
        emptyInspector
      }
    case .vfxVideoComponent:
      if let internalID = selector.internalID {
        VfxVideoComponentInspector(
          uiState: uiState, internalID: internalID, windowRuntime: windowRuntime)
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
          uiState: uiState, internalID: internalID, windowRuntime: windowRuntime)
      } else {
        emptyInspector
      }
    case .testPatternVideoComponent:
      if let internalID = selector.internalID {
        TestPatternInspector(
          uiState: uiState, internalID: internalID, windowRuntime: windowRuntime)
      } else {
        emptyInspector
      }
    case .ocrVision:
      if let internalID = selector.internalID {
        OcrVisionInspector(
          uiState: uiState, internalID: internalID, windowRuntime: windowRuntime)
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
    Text("This Inspector requires a Workspace windowRuntime.")
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

      WorkspaceInspectorContainer(uiState: uiState, appletData: WorkspaceAppletData())
        .padding(16)
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 520, minHeight: 640)
  }
#endif
