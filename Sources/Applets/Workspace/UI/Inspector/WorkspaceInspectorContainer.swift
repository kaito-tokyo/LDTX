// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXProgramRuntime
import LDTXTaskQueue
import LDTXYouTubeRTMPS
import SwiftUI

import AppKit

public struct WorkspaceInspectorContainer: View {
  @Environment(\.workspaceReportError) private var reportError
  private var workspaceURL: URL? { storeService.localStateURL }
  let deviceRegistry: DeviceRegistryService
  @Bindable var appletData: WorkspaceAppletData
  @Bindable var storeService: WorkspaceStoreService
  private let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  private weak var document: NSDocument?
  let editingState: WorkspaceEditingState

  public init(
    deviceRegistry: DeviceRegistryService,
    storeService: WorkspaceStoreService, editingState: WorkspaceEditingState,
    appletData: WorkspaceAppletData,
    document: NSDocument? = nil,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)? = { nil }
  ) {
    self.document = document
    self.editingState = editingState
    self.runtimeActions = runtimeActions
    self.deviceRegistry = deviceRegistry
    self._appletData = Bindable(wrappedValue: appletData)
    self._storeService = Bindable(wrappedValue: storeService)
  }

  public var body: some View {
    if let selector = storeService.inspectorSelector {
      inspector(for: selector)
        .id(selector)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("Inspector")
            .font(.headline)
          Text("Select an item in the Sidebar to view and edit its settings.")
          Text(
            "Select Programs to add or choose a Program, Canvas to configure frame rate and bit rate, or Output to configure recording and streaming."
          )
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  @ViewBuilder
  private func inspector(for selector: WorkspaceInspectorSelector) -> some View {
    switch selector.kind {
    case .invalid:
      emptyInspector
    case .workspacePrograms:
      WorkspaceProgramsInspector(
        storeService: storeService, editingState: editingState, appletData: appletData,
        runtimeActions: runtimeActions)
    case .workspaceCanvas:
      WorkspaceCanvasInspector(storeService: storeService)
    case .workspaceOutput:
      if let externalID = storeService.externalID.flatMap(UUID.init(uuidString:)) {
        WorkspaceOutputInspector(
          outputSettings: $storeService.workspaceOutputSettings, externalID: externalID,
          isOutputActive: storeService.isOutputActive, appletData: appletData,
          reportError: reportError)
      } else {
        unavailablePreviewInspector
      }
    case .audioInputDevice:
      if let internalID = selector.internalID {
        AudioInputDeviceInspector(
          document: document, storeService: storeService, internalID: internalID,
          deviceRegistry: deviceRegistry,
          appletData: appletData, runtimeActions: runtimeActions)
      } else {
        emptyInspector
      }
    case .vfxVideoComponent:
      if let internalID = selector.internalID {
        VfxVideoComponentInspector(
          storeService: storeService, internalID: internalID,
          deviceRegistry: deviceRegistry, appletData: appletData, runtimeActions: runtimeActions)
      } else {
        emptyInspector
      }
    case .solidColorFillVideoComponent:
      if let internalID = selector.internalID {
        SolidColorFillVideoComponentInspector(
          storeService: storeService,
          appletData: appletData,
          videoComponentID: internalID)
      } else {
        emptyInspector
      }
    case .linearGradientFillVideoComponent:
      if let internalID = selector.internalID {
        LinearGradientFillVideoComponentInspector(
          storeService: storeService,
          appletData: appletData,
          videoComponentID: internalID)
      } else {
        emptyInspector
      }
    case .radialGradientFillVideoComponent:
      if let internalID = selector.internalID {
        RadialGradientFillVideoComponentInspector(
          storeService: storeService,
          appletData: appletData,
          videoComponentID: internalID)
      } else {
        emptyInspector
      }
    case .conicGradientFillVideoComponent:
      if let internalID = selector.internalID {
        ConicGradientFillVideoComponentInspector(
          storeService: storeService,
          appletData: appletData,
          videoComponentID: internalID)
      } else {
        emptyInspector
      }
    case .clockVideoComponent:
      if let internalID = selector.internalID {
        ClockInspector(
          storeService: storeService, appletData: appletData, internalID: internalID)
      } else {
        emptyInspector
      }
    case .testPatternVideoComponent:
      if let internalID = selector.internalID {
        TestPatternInspector(
          storeService: storeService, appletData: appletData, internalID: internalID)
      } else {
        emptyInspector
      }
    case .ocrVision:
      if let internalID = selector.internalID,
        let vision = $storeService.ocrVision(internalID: internalID)
      {
        OcrVisionInspector(
          storeService: storeService, editingState: editingState, vision: vision)
      } else {
        emptyInspector
      }
    case .ldtxSceneDetectorVision:
      if let internalID = selector.internalID,
        let vision = $storeService.ldtxSceneDetectorVision(internalID: internalID)
      {
        let name = vision.wrappedValue.modelFileName
        let savedModelURL: URL? =
          name.isEmpty
          ? nil
          : workspaceURL?.appendingPathComponent(
            "VisionModels/\(internalID)/\(name)")
        LdtxSceneDetectorVisionInspector(
          videoComponents: storeService.workspaceDefinition.videoComponents,
          inputSize: vision.wrappedValue.videoComponentInternalIDIfPresent.flatMap { inputID in
            storeService.workspaceDefinition.videoComponents.first { $0.internalID == inputID }?
              .renderingSize
          },
          vision: vision,
          modelURL: Binding(
            get: { storeService.modelURLs[internalID] ?? savedModelURL },
            set: { storeService.modelURLs[internalID] = .some($0) }),
          savedModelURL: savedModelURL,
          inferenceResult: storeService.visionResults[internalID],
          inferenceFailure: storeService.visionFailureMessages[internalID]
        )
        .environment(\.outputActive, storeService.isOutputActive)
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
    @Previewable @State var editingState = WorkspaceEditingState()
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .solidColorFillVideoComponent, internalID: 4))

    HStack(spacing: 0) {
      WorkspaceSidebar(
        storeService: storeService, editingState: editingState,
        deviceRegistry: DeviceRegistryService(),
        appletData: WorkspaceAppletData()
      )
      .frame(width: 230)

      Divider()

      WorkspaceInspectorContainer(
        deviceRegistry: DeviceRegistryService(), storeService: storeService,
        editingState: editingState, appletData: WorkspaceAppletData()
      )
      .padding(16)
      .frame(width: 260)
      .frame(maxHeight: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 520, minHeight: 640)
  }
#endif
