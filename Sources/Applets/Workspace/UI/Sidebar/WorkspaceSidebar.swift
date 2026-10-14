// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXProgramRuntime
import LDTXTaskQueue
import LDTXYouTubeRTMPS
import SwiftUI

public struct WorkspaceSidebar: View {
  @Bindable var stateService: WorkspaceStateService
  private let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  private let deviceRegistry: DeviceRegistryService
  private let appletData: WorkspaceAppletData
  private weak var document: (any WorkspaceDocumentContext)?
  @State private var addSheet: WorkspaceAddSheet?
  @State private var draft = WorkspaceAddDraft()
  @State private var additionFailure: String?

  public init(
    stateService: WorkspaceStateService, deviceRegistry: DeviceRegistryService,
    appletData: WorkspaceAppletData,
    document: (any WorkspaceDocumentContext)? = nil,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)? = { nil }
  ) {
    self.document = document
    self.runtimeActions = runtimeActions
    self.deviceRegistry = deviceRegistry
    self.appletData = appletData
    self._stateService = Bindable(wrappedValue: stateService)
  }

  static func rows<Value>(
    _ values: [Value], internalID: (Value) -> Int64?
  ) -> [(id: Int64, value: Value, isSelectable: Bool)] {
    let ids = values.map(internalID)
    let counts = ids.compactMap { $0 }.filter { $0 > 0 }
      .reduce(into: [Int64: Int]()) { $0[$1, default: 0] += 1 }
    return values.enumerated().map { index, value in
      if let id = ids[index], id > 0, counts[id] == 1 {
        return (id, value, true)
      }
      return (-Int64(index) - 1, value, false)
    }
  }

  public var body: some View {
    let inputDevices = Self.rows(stateService.workspaceDefinition.audioDevices) {
      $0.hasInternalID ? $0.internalID : nil
    }
    let videoComponents = Self.rows(stateService.workspaceDefinition.videoComponents) {
      $0.internalID
    }
    let visions = Self.rows(stateService.workspaceDefinition.visions) { $0.internalID }

    VStack {
      List(selection: $stateService.inspectorSelector) {
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
          ForEach(inputDevices, id: \.id) { row in
            let device = row.value
            if row.isSelectable {
              Label(device.displayName, systemImage: "waveform")
                .tag(
                  WorkspaceInspectorSelector(kind: .audioInputDevice, internalID: device.internalID)
                )
            } else {
              Label(device.displayName, systemImage: "waveform").disabled(true)
            }
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
          ForEach(videoComponents, id: \.id) { row in
            let component = row.value
            if row.isSelectable {
              switch component.videoComponent {
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
            } else {
              Label(component.displayName ?? "(invalid)", systemImage: "questionmark.square.dashed")
                .disabled(true)
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
          ForEach(visions, id: \.id) { row in
            let vision = row.value
            if row.isSelectable {
              switch vision.vision {
              case .ocrVision(let ocrVision):
                Label(ocrVision.displayName, systemImage: "eye")
                  .tag(
                    WorkspaceInspectorSelector(
                      kind: .ocrVision, internalID: ocrVision.internalID))
              case .ldtxSceneDetectorVision(let classifierVision):
                Label(classifierVision.displayName, systemImage: "eye")
                  .tag(
                    WorkspaceInspectorSelector(
                      kind: .ldtxSceneDetectorVision,
                      internalID: classifierVision.internalID))
              case nil:
                Label("(invalid)", systemImage: "questionmark.square.dashed")
              }
            } else {
              Label(vision.displayName ?? "(invalid)", systemImage: "questionmark.square.dashed")
                .disabled(true)
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
        videoComponents: stateService.workspaceDefinition.videoComponents,
        validationMessage: document == nil
          ? "The Workspace document is unavailable."
          : additionFailure
            ?? WorkspaceResourceAddition.validationMessage(
              sheet: sheet, draft: draft, devices: deviceOptions, stateService: stateService,
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
      + deviceRegistry.cameras.map {
        .init(
          id: .avCaptureDevice(uniqueID: $0.id), name: $0.name,
          width: UInt32(exactly: $0.width) ?? 0, height: UInt32(exactly: $0.height) ?? 0)
      }
  }

  var canAddResource: Bool { document != nil && !stateService.isOutputActive }

  private func beginAdding(_ sheet: WorkspaceAddSheet) {
    guard canAddResource else { return }
    if sheet == .device || sheet == .videoComponent { deviceRegistry.refresh() }
    additionFailure = nil
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
      additionFailure = error.localizedDescription
    }
  }

  func addResource(_ sheet: WorkspaceAddSheet, draft: WorkspaceAddDraft) throws {
    guard document != nil else {
      throw WorkspaceSelectionError(message: "The Workspace document is unavailable.")
    }
    let selectsCamera = sheet == .videoComponent && draft.componentKind == .vfxSource
    if sheet == .device || selectsCamera {
      deviceRegistry.refresh(reportErrors: false)
      if sheet == .device, let error = deviceRegistry.error { throw error }
    }
    let id = try WorkspaceResourceAddition.add(
      sheet: sheet, draft: draft, devices: deviceOptions, stateService: stateService,
      audioDiscoveryError: deviceRegistry.errorMessage)
    if sheet == .device || selectsCamera {
      appletData.setPhysicalDeviceID(draft.physicalDeviceID, for: id)
      runtimeActions()?.synchronizeCaptureInputs(
        availableCameraIDs: Set(deviceRegistry.cameras.map(\.id))
      ) { _ in }
      runtimeActions()?.synchronizeAudioMonitor()
    }
  }

}

#if DEBUG
  #Preview("Workspace Sidebar") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState()
    WorkspaceSidebar(
      stateService: stateService, deviceRegistry: DeviceRegistryService(),
      appletData: WorkspaceAppletData()
    )
    .frame(width: 260, height: 640)
  }
#endif
