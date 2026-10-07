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
    return document.fileURL ?? storeService.localStateURL
  }
  let deviceRegistry: DeviceRegistryService
  @Bindable var appletData: WorkspaceAppletData
  @Bindable var storeService: WorkspaceStoreService

  public init(
    deviceRegistry: DeviceRegistryService,
    storeService: WorkspaceStoreService,
    appletData: WorkspaceAppletData
  ) {
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
      WorkspaceProgramsInspector(storeService: storeService, appletData: appletData)
    case .workspaceCanvas:
      WorkspaceCanvasInspector(storeService: storeService)
    case .workspaceOutput:
      if workspaceURL != nil {
        WorkspaceOutputInspector(
          storeService: storeService, appletData: appletData)
      } else {
        unavailablePreviewInspector
      }
    case .audioInputDevice:
      if let internalID = selector.internalID {
        AudioInputDeviceInspector(
          storeService: storeService, internalID: internalID,
          deviceRegistry: deviceRegistry,
          appletData: appletData)
      } else {
        emptyInspector
      }
    case .vfxVideoComponent:
      if let internalID = selector.internalID {
        VfxVideoComponentInspector(
          storeService: storeService, internalID: internalID,
          deviceRegistry: deviceRegistry, appletData: appletData)
      } else {
        emptyInspector
      }
    case .solidColorFillVideoComponent:
      if let internalID = selector.internalID {
        SolidColorFillVideoComponentInspector(
          storeService: storeService,
          videoComponentID: .solidColorFill(internalID))
      } else {
        emptyInspector
      }
    case .linearGradientFillVideoComponent:
      if let internalID = selector.internalID {
        LinearGradientFillVideoComponentInspector(
          storeService: storeService,
          videoComponentID: .linearGradientFill(internalID))
      } else {
        emptyInspector
      }
    case .radialGradientFillVideoComponent:
      if let internalID = selector.internalID {
        RadialGradientFillVideoComponentInspector(
          storeService: storeService,
          videoComponentID: .radialGradientFill(internalID))
      } else {
        emptyInspector
      }
    case .conicGradientFillVideoComponent:
      if let internalID = selector.internalID {
        ConicGradientFillVideoComponentInspector(
          storeService: storeService,
          videoComponentID: .conicGradientFill(internalID))
      } else {
        emptyInspector
      }
    case .clockVideoComponent:
      if let internalID = selector.internalID {
        ClockInspector(
          storeService: storeService, internalID: internalID)
      } else {
        emptyInspector
      }
    case .testPatternVideoComponent:
      if let internalID = selector.internalID {
        TestPatternInspector(
          storeService: storeService, internalID: internalID)
      } else {
        emptyInspector
      }
    case .ocrVision:
      if let internalID = selector.internalID {
        OcrVisionInspector(
          storeService: storeService, internalID: internalID)
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
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .solidColorFillVideoComponent, internalID: 4))

    HStack(spacing: 0) {
      WorkspaceSidebar(
        storeService: storeService, deviceRegistry: DeviceRegistryService(),
        appletData: WorkspaceAppletData()
      )
      .frame(width: 230)

      Divider()

      WorkspaceInspectorContainer(
        deviceRegistry: DeviceRegistryService(), storeService: storeService,
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
