// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXProgramRuntime
import LDTXTaskQueue
import LDTXWorkspaceBundleFormat
import LDTXYouTubeRTMPS
import SwiftUI

public struct WorkspaceInspectorContainer: View {
  @Environment(\.workspaceReportError) private var reportError
  private var workspaceURL: URL? { stateService.localStateURL }
  let deviceRegistry: DeviceRegistryService
  @Bindable var appletData: WorkspaceAppletData
  @Bindable var stateService: WorkspaceStateService
  private let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  private weak var document: (any WorkspaceDocumentContext)?

  public init(
    deviceRegistry: DeviceRegistryService,
    stateService: WorkspaceStateService, appletData: WorkspaceAppletData,
    document: (any WorkspaceDocumentContext)? = nil,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)? = { nil }
  ) {
    self.document = document
    self.runtimeActions = runtimeActions
    self.deviceRegistry = deviceRegistry
    self._appletData = Bindable(wrappedValue: appletData)
    self._stateService = Bindable(wrappedValue: stateService)
  }

  public var body: some View {
    if let selector = stateService.inspectorSelector {
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
        stateService: stateService, appletData: appletData,
        runtimeActions: runtimeActions)
    case .workspaceCanvas:
      WorkspaceCanvasInspector(stateService: stateService)
    case .workspaceOutput:
      if let externalID = stateService.externalID.flatMap(UUID.init(uuidString:)) {
        WorkspaceOutputInspector(
          outputSettings: $stateService.workspaceOutputSettings, externalID: externalID,
          isOutputActive: stateService.isOutputActive, appletData: appletData,
          reportError: reportError)
      } else {
        unavailablePreviewInspector
      }
    case .audioInputDevice:
      if let internalID = selector.internalID {
        AudioInputDeviceInspector(
          document: document, stateService: stateService, internalID: internalID,
          deviceRegistry: deviceRegistry,
          appletData: appletData, runtimeActions: runtimeActions)
      } else {
        emptyInspector
      }
    case .vfxVideoComponent:
      if let internalID = selector.internalID {
        VfxVideoComponentInspector(
          stateService: stateService, internalID: internalID,
          deviceRegistry: deviceRegistry, appletData: appletData, runtimeActions: runtimeActions)
      } else {
        emptyInspector
      }
    case .solidColorFillVideoComponent:
      if let internalID = selector.internalID {
        SolidColorFillVideoComponentInspector(
          stateService: stateService,
          appletData: appletData,
          videoComponentID: internalID)
      } else {
        emptyInspector
      }
    case .linearGradientFillVideoComponent:
      if let internalID = selector.internalID {
        LinearGradientFillVideoComponentInspector(
          stateService: stateService,
          appletData: appletData,
          videoComponentID: internalID)
      } else {
        emptyInspector
      }
    case .radialGradientFillVideoComponent:
      if let internalID = selector.internalID {
        RadialGradientFillVideoComponentInspector(
          stateService: stateService,
          appletData: appletData,
          videoComponentID: internalID)
      } else {
        emptyInspector
      }
    case .conicGradientFillVideoComponent:
      if let internalID = selector.internalID {
        ConicGradientFillVideoComponentInspector(
          stateService: stateService,
          appletData: appletData,
          videoComponentID: internalID)
      } else {
        emptyInspector
      }
    case .clockVideoComponent:
      if let internalID = selector.internalID {
        ClockInspector(
          stateService: stateService, appletData: appletData, internalID: internalID)
      } else {
        emptyInspector
      }
    case .testPatternVideoComponent:
      if let internalID = selector.internalID {
        TestPatternInspector(
          stateService: stateService, appletData: appletData, internalID: internalID)
      } else {
        emptyInspector
      }
    case .ocrVision:
      if let internalID = selector.internalID,
        let vision = $stateService.ocrVision(internalID: internalID)
      {
        OcrVisionInspector(
          stateService: stateService, vision: vision)
      } else {
        emptyInspector
      }
    case .ldtxSceneDetectorVision:
      if let internalID = selector.internalID,
        let vision = $stateService.ldtxSceneDetectorVision(internalID: internalID)
      {
        LdtxSceneDetectorVisionInspector(
          videoComponents: stateService.workspaceDefinition.videoComponents,
          inputSize: vision.wrappedValue.videoComponentInternalIDIfPresent.flatMap { inputID in
            stateService.workspaceDefinition.videoComponents.first { $0.internalID == inputID }?
              .renderingSize
          },
          vision: vision,
          modelURL: Binding(
            get: { stateService.visionModels[vision.wrappedValue.modelInternalID] },
            set: { stateService.setVisionModelURL($0, for: internalID) }),
          inferenceResult: stateService.visionResults[internalID],
          inferenceFailure: stateService.visionFailureMessages[internalID],
          modelPreparationGeneration: stateService.modelPreparationGeneration
        )
        .environment(\.outputActive, stateService.isOutputActive)
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
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .solidColorFillVideoComponent, internalID: 4))

    HStack(spacing: 0) {
      WorkspaceSidebar(
        stateService: stateService, deviceRegistry: DeviceRegistryService(),
        appletData: WorkspaceAppletData()
      )
      .frame(width: 230)

      Divider()

      WorkspaceInspectorContainer(
        deviceRegistry: DeviceRegistryService(), stateService: stateService,
        appletData: WorkspaceAppletData()
      )
      .padding(16)
      .frame(width: 260)
      .frame(maxHeight: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 520, minHeight: 640)
  }
#endif
