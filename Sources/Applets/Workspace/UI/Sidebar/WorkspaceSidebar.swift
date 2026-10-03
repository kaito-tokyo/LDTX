// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import SwiftUI

public struct WorkspaceSidebar: View {
  @Bindable var uiState: WorkspaceUIState
  private let deviceRegistry: DeviceRegistryService
  private let appletData: WorkspaceAppletData
  @Environment(\.documentReference) private var documentReference
  @Environment(\.workspaceDispatcher) private var dispatcher
  @State private var addSheet: WorkspaceAddSheet?
  @State private var draft = WorkspaceAddDraft()
  @State private var additionError: String?

  public init(
    uiState: WorkspaceUIState,
    deviceRegistry: DeviceRegistryService,
    appletData: WorkspaceAppletData
  ) {
    self.deviceRegistry = deviceRegistry
    self.appletData = appletData
    self._uiState = Bindable(wrappedValue: uiState)
  }

  public var body: some View {
    let inputDevices = uiState.definition.inputDevices
    let videoComponents = uiState.definition.videoComponents
    let visions = uiState.definition.visions

    VStack {
      List(selection: $uiState.inspectorSelector) {
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
            switch device.definition {
            case .audioDevice(let audioDevice):
              Label(audioDevice.displayName, systemImage: "waveform")
                .tag(
                  WorkspaceInspectorSelector(
                    kind: .audioInputDevice, internalID: audioDevice.internalID))
            case .videoDevice(let videoDevice):
              Label(videoDevice.displayName, systemImage: "video")
                .tag(
                  WorkspaceInspectorSelector(
                    kind: .videoInputDevice, internalID: videoDevice.internalID))
            case nil:
              Label("(invalid)", systemImage: "questionmark.square.dashed")
            }
          }

          Button {
            beginAdding(.device)
          } label: {
            Label("Add device...", systemImage: "plus")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .disabled(!canAddResource)
        } header: {
          Text("INPUT DEVICES")
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
    .onChange(of: draft) { _, _ in additionError = nil }
    .sheet(item: $addSheet) { sheet in
      WorkspaceAddResourceSheet(
        sheet: sheet, draft: $draft, devices: deviceOptions,
        videoInputs: uiState.definition.inputDevices.compactMap {
          if case .videoDevice(let device) = $0.definition { return device }
          return nil
        },
        validationMessage: documentReference?.document == nil
          ? "The Workspace document is unavailable."
          : WorkspaceResourceAddition.validationMessage(
            sheet: sheet, draft: draft, devices: deviceOptions, uiState: uiState,
            audioDiscoveryError: deviceRegistry.errorMessage),
        errorMessage: additionError,
        submit: { submitResource(sheet) }, cancel: { addSheet = nil },
        refresh: {
          deviceRegistry.refresh()
          additionError = nil
        }, deviceDiscoveryMessage: deviceRegistry.errorMessage)
    }
  }

  private var deviceOptions: [WorkspaceAddDeviceOption] {
    deviceRegistry.cameras.map {
      .init(id: .avCaptureDevice(uniqueID: $0.id), name: $0.name)
    }
      + deviceRegistry.audioInputDevices.map {
        .init(id: .coreAudioDevice(uid: $0.id), name: $0.name)
      }
  }

  var canAddResource: Bool { documentReference?.document != nil && !uiState.isOutputActive }

  private func beginAdding(_ sheet: WorkspaceAddSheet) {
    guard canAddResource else { return }
    if sheet == .device { deviceRegistry.refresh() }
    draft = WorkspaceAddDraft()
    if sheet == .videoComponent { draft.name = draft.componentKind.rawValue }
    if sheet == .vision { draft.name = "OCR Vision" }
    additionError = nil
    addSheet = sheet
  }

  private func submitResource(_ sheet: WorkspaceAddSheet) {
    do {
      try addResource(sheet, draft: draft)
      additionError = nil
      addSheet = nil
    } catch {
      additionError = error.localizedDescription
    }
  }

  func addResource(_ sheet: WorkspaceAddSheet, draft: WorkspaceAddDraft) throws {
    guard documentReference?.document != nil else {
      throw WorkspaceSelectionError(message: "The Workspace document is unavailable.")
    }
    if sheet == .device { deviceRegistry.refresh() }
    let id = try WorkspaceResourceAddition.add(
      sheet: sheet, draft: draft, devices: deviceOptions, uiState: uiState,
      audioDiscoveryError: deviceRegistry.errorMessage)
    if sheet == .device {
      appletData.setPhysicalDeviceID(draft.physicalDeviceID, for: id)
      dispatcher?.synchronizeCaptureInputs(
        availableCameraIDs: Set(deviceRegistry.cameras.map(\.id))
      ) { _ in }
      dispatcher?.synchronizeAudioMonitor()
    }
    if sheet == .vision { dispatcher?.synchronizeVision() }
  }

}

#Preview("Workspace Sidebar") {
  @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState()
  WorkspaceSidebar(
    uiState: uiState, deviceRegistry: DeviceRegistryService(), appletData: WorkspaceAppletData()
  )
  .frame(width: 260, height: 640)
}
