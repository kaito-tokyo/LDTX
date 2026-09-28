// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletData
import LDTXWorkspaceAppletInterface
import SwiftUI

#if DEBUG
  import AppKit
#endif

public struct WorkspaceInspectorContainer: View {
  let store: any WorkspaceBundleStoreProtocol
  let windowRuntime: (any WorkspaceWindowRuntimeProtocol)?
  let recordingSession: (any WorkspaceRecordingSessionProtocol)?
  let deviceMappingAppletData: WorkspaceDeviceAppletData?
  @Bindable var uiState: WorkspaceUIState

  public init(
    store: any WorkspaceBundleStoreProtocol,
    windowRuntime: any WorkspaceWindowRuntimeProtocol,
    recordingSession: any WorkspaceRecordingSessionProtocol,
    uiState: WorkspaceUIState,
    deviceMappingAppletData: WorkspaceDeviceAppletData? = nil
  ) {
    self.store = store
    self.windowRuntime = windowRuntime
    self.recordingSession = recordingSession
    self.deviceMappingAppletData = deviceMappingAppletData
    self._uiState = Bindable(wrappedValue: uiState)
  }

  init(
    store: any WorkspaceBundleStoreProtocol,
    uiState: WorkspaceUIState,
    deviceMappingAppletData: WorkspaceDeviceAppletData? = nil
  ) {
    self.store = store
    self.windowRuntime = nil
    self.recordingSession = nil
    self.deviceMappingAppletData = deviceMappingAppletData
    self._uiState = Bindable(wrappedValue: uiState)
  }

  public var body: some View {
    switch uiState.inspectorKind {
    case .programVideoLayers:
      ProgramVideoLayersInspector(
        uiState: uiState,
        store: store,
        windowRuntime: windowRuntime,
        recordingSession: recordingSession)
    case .workspaceCanvas:
      if let windowRuntime, let recordingSession {
        WorkspaceCanvasInspector(
          store: store, windowRuntime: windowRuntime, recordingSession: recordingSession,
          uiState: uiState)
      } else {
        unavailablePreviewInspector
      }
    case .workspaceOutput:
      if let windowRuntime, let recordingSession {
        WorkspaceOutputInspector(
          store: store, windowRuntime: windowRuntime, recordingSession: recordingSession)
      } else {
        unavailablePreviewInspector
      }
    case .audioInputDevice(let internalID):
      AudioInputDeviceInspector(
        uiState: uiState, internalID: internalID, windowRuntime: windowRuntime,
        recordingSession: recordingSession, deviceMappingAppletData: deviceMappingAppletData)
    case .videoInputDevice(let internalID):
      VideoInputDeviceInspector(
        uiState: uiState, internalID: internalID, windowRuntime: windowRuntime,
        recordingSession: recordingSession, deviceMappingAppletData: deviceMappingAppletData)
    case .vfxVideoComponent(let internalID):
      VfxVideoComponentInspector(
        uiState: uiState, internalID: internalID, windowRuntime: windowRuntime,
        recordingSession: recordingSession)
    case .solidColorFillVideoComponent(let internalID):
      SolidColorFillVideoComponentInspector(
        uiState: uiState,
        videoComponentID: .solidColorFill(internalID))
    case .linearGradientFillVideoComponent(let internalID):
      LinearGradientFillVideoComponentInspector(
        uiState: uiState,
        videoComponentID: .linearGradientFill(internalID))
    case .radialGradientFillVideoComponent(let internalID):
      RadialGradientFillVideoComponentInspector(
        uiState: uiState,
        videoComponentID: .radialGradientFill(internalID))
    case .conicGradientFillVideoComponent(let internalID):
      ConicGradientFillVideoComponentInspector(
        uiState: uiState,
        videoComponentID: .conicGradientFill(internalID))
    case .clockVideoComponent(let internalID):
      ClockInspector(
        uiState: uiState, internalID: internalID, windowRuntime: windowRuntime,
        recordingSession: recordingSession)
    case .testPatternVideoComponent(let internalID):
      TestPatternInspector(
        uiState: uiState, internalID: internalID, windowRuntime: windowRuntime,
        recordingSession: recordingSession)
    case .ocrVision(let internalID):
      OcrVisionInspector(
        uiState: uiState, internalID: internalID, windowRuntime: windowRuntime,
        recordingSession: recordingSession)
    case nil:
      Text("Select a Workspace item to inspect it.")
        .foregroundStyle(.secondary)
    }
  }

  private var unavailablePreviewInspector: some View {
    Text("This Inspector requires a Workspace windowRuntime.")
      .foregroundStyle(.secondary)
  }

}

#if DEBUG
  #Preview("Workspace Inspector — Sidebar") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorKind: .solidColorFillVideoComponent(4))
    let workspaceBundleStore = NullWorkspaceBundleStore()

    HStack(spacing: 0) {
      WorkspaceSidebar(
        workspaceBundleStore: workspaceBundleStore,
        uiState: uiState
      )
      .frame(width: 230)

      Divider()

      WorkspaceInspectorContainer(store: workspaceBundleStore, uiState: uiState)
        .padding(16)
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 520, minHeight: 640)
  }
#endif
