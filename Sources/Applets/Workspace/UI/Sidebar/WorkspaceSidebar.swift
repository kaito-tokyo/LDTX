// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import SwiftUI

public struct WorkspaceSidebar: View {
  @Bindable var storeService: WorkspaceStoreService
  private let deviceRegistry: DeviceRegistryService
  private let appletData: WorkspaceAppletData
  @Environment(\.documentReference) private var documentReference
  @State private var addSheet: WorkspaceAddSheet?
  @State private var draft = WorkspaceAddDraft()

  public init(
    storeService: WorkspaceStoreService,
    deviceRegistry: DeviceRegistryService,
    appletData: WorkspaceAppletData
  ) {
    self.deviceRegistry = deviceRegistry
    self.appletData = appletData
    self._storeService = Bindable(wrappedValue: storeService)
  }

  public var body: some View {
    let inputDevices = storeService.definition.audioDevices
    let videoComponents = storeService.definition.videoComponents
    let visions = storeService.definition.visions

    VStack {
      List(selection: $storeService.inspectorSelector) {
        Section {
          Label("Programs", systemImage: "rectangle.stack")
            .tag(WorkspaceInspectorSelector(kind: .workspacePrograms))
          Label("Canvas", systemImage: "rectangle.on.rectangle")
            .tag(WorkspaceInspectorSelector(kind: .workspaceCanvas))
          Label("Output", systemImage: "dot.radiowaves.left.and.right")
            .tag(WorkspaceInspectorSelector(kind: .workspaceOutput))
        } header: {
          Text("WORKSPACE")
        }

        Section {
          ForEach(inputDevices) { device in
            Label(device.displayName, systemImage: "waveform")
              .tag(
                WorkspaceInspectorSelector(kind: .audioInputDevice, internalID: device.internalID))
          }

          Button {
            beginAdding(.device)
          } label: {
            Label("Add audio device...", systemImage: "plus")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .disabled(!canAddResource)
        } header: {
          Text("AUDIO DEVICES")
        }

        Section {
          ForEach(videoComponents) { component in
            switch component.definition {
            case .vfxSource(let source):
              Label(source.displayName, systemImage: "play.rectangle")
                .tag(
                  WorkspaceInspectorSelector(
                    kind: .vfxVideoComponent, internalID: source.internalID))
            case .solidColorFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(
                  WorkspaceInspectorSelector(
                    kind: .solidColorFillVideoComponent, internalID: fill.internalID))
            case .linearGradientFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(
                  WorkspaceInspectorSelector(
                    kind: .linearGradientFillVideoComponent, internalID: fill.internalID))
            case .radialGradientFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(
                  WorkspaceInspectorSelector(
                    kind: .radialGradientFillVideoComponent, internalID: fill.internalID))
            case .conicGradientFill(let fill):
              Label(fill.displayName, systemImage: "paintpalette")
                .tag(
                  WorkspaceInspectorSelector(
                    kind: .conicGradientFillVideoComponent, internalID: fill.internalID))
            case .clock(let clock):
              Label(clock.displayName, systemImage: "clock")
                .tag(
                  WorkspaceInspectorSelector(
                    kind: .clockVideoComponent, internalID: clock.internalID))
            case .testPattern(let testPattern):
              Label(testPattern.displayName, systemImage: "testtube.2")
                .tag(
                  WorkspaceInspectorSelector(
                    kind: .testPatternVideoComponent, internalID: testPattern.internalID))
            case nil:
              Label("(invalid)", systemImage: "questionmark.square.dashed")
            }
          }

          Button {
            beginAdding(.videoComponent)
          } label: {
            Label("Add video component...", systemImage: "plus")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .disabled(!canAddResource)
        } header: {
          Text("VIDEO COMPONENTS")
        }

        Section {
          ForEach(visions) { vision in
            switch vision.definition {
            case .ocrVision(let ocrVision):
              Label(ocrVision.displayName, systemImage: "eye")
                .tag(
                  WorkspaceInspectorSelector(
                    kind: .ocrVision, internalID: ocrVision.internalID))
            case nil:
              Label("(invalid)", systemImage: "questionmark.square.dashed")
            }
          }

          Button {
            beginAdding(.vision)
          } label: {
            Label("Add vision...", systemImage: "plus")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .disabled(!canAddResource)
        } header: {
          Text("VISIONS")
        }
      }
    }
    .listStyle(.sidebar)
    .sheet(item: $addSheet) { sheet in
      WorkspaceAddResourceSheet(
        sheet: sheet, draft: $draft, devices: deviceOptions,
        videoComponents: storeService.definition.videoComponents,
        validationMessage: documentReference?.document == nil
          ? "The Workspace document is unavailable."
          : WorkspaceResourceAddition.validationMessage(
            sheet: sheet, draft: draft, devices: deviceOptions, storeService: storeService,
            audioDiscoveryError: deviceRegistry.errorMessage),
        submit: { submitResource(sheet) }, cancel: { addSheet = nil },
        refresh: {
          deviceRegistry.refresh()
        }, deviceDiscoveryMessage: deviceRegistry.errorMessage)
    }
  }

  private var deviceOptions: [WorkspaceAddDeviceOption] {
    deviceRegistry.audioInputDevices.map {
      .init(id: .coreAudioDevice(uid: $0.id), name: $0.name)
    }
  }

  var canAddResource: Bool { documentReference?.document != nil && !storeService.isOutputActive }

  private func beginAdding(_ sheet: WorkspaceAddSheet) {
    guard canAddResource else { return }
    if sheet == .device { deviceRegistry.refresh() }
    draft = WorkspaceAddDraft()
    if sheet == .videoComponent { draft.name = draft.componentKind.rawValue }
    if sheet == .vision { draft.name = "OCR Vision" }
    addSheet = sheet
  }

  private func submitResource(_ sheet: WorkspaceAddSheet) {
    do {
      try addResource(sheet, draft: draft)
      addSheet = nil
    } catch {
      storeService.reportError(error)
    }
  }

  func addResource(_ sheet: WorkspaceAddSheet, draft: WorkspaceAddDraft) throws {
    guard documentReference?.document != nil else {
      throw WorkspaceSelectionError(message: "The Workspace document is unavailable.")
    }
    if sheet == .device {
      deviceRegistry.refresh(reportErrors: false)
      if let error = deviceRegistry.error { throw error }
    }
    let id = try WorkspaceResourceAddition.add(
      sheet: sheet, draft: draft, devices: deviceOptions, storeService: storeService,
      audioDiscoveryError: deviceRegistry.errorMessage)
    if sheet == .device {
      appletData.setPhysicalDeviceID(draft.physicalDeviceID, for: id)
      storeService.synchronizeCaptureInputs(
        availableCameraIDs: Set(deviceRegistry.cameras.map(\.id))
      ) { _ in }
      storeService.synchronizeAudioMonitor()
    }
    if sheet == .vision { storeService.synchronizeVision() }
  }

}

#Preview("Workspace Sidebar") {
  @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState()
  WorkspaceSidebar(
    storeService: storeService, deviceRegistry: DeviceRegistryService(),
    appletData: WorkspaceAppletData()
  )
  .frame(width: 260, height: 640)
}
