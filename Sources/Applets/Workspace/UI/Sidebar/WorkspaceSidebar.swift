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
  @Bindable var storeService: WorkspaceStoreService
  private let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  let editingState: WorkspaceEditingState
  private let deviceRegistry: DeviceRegistryService
  private let appletData: WorkspaceAppletData
  private let onSelectionBlocked: () -> Void
  private weak var document: NSDocument?
  @State private var addSheet: WorkspaceAddSheet?
  @State private var draft = WorkspaceAddDraft()
  @State private var additionFailure: String?
  @State private var displayedSelection: WorkspaceInspectorSelector?

  public init(
    storeService: WorkspaceStoreService, editingState: WorkspaceEditingState,
    deviceRegistry: DeviceRegistryService,
    appletData: WorkspaceAppletData,
    document: NSDocument? = nil,
    onSelectionBlocked: @escaping () -> Void = {},
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)? = { nil }
  ) {
    self.document = document
    self.editingState = editingState
    self.runtimeActions = runtimeActions
    self.deviceRegistry = deviceRegistry
    self.appletData = appletData
    self.onSelectionBlocked = onSelectionBlocked
    self._storeService = Bindable(wrappedValue: storeService)
    self._displayedSelection = State(initialValue: storeService.inspectorSelector)
  }

  @discardableResult
  static func select(
    _ selection: WorkspaceInspectorSelector?, storeService: WorkspaceStoreService,
    editingState: WorkspaceEditingState,
    onBlocked: () -> Void = {}
  ) -> Bool {
    guard selection != storeService.inspectorSelector else { return true }
    editingState.refreshUnconfirmedChanges()
    guard !editingState.hasUnconfirmedChanges else {
      onBlocked()
      return false
    }
    storeService.inspectorSelector = selection
    return true
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
    let inputDevices = Self.rows(storeService.workspaceDefinition.audioDevices) {
      $0.hasInternalID ? $0.internalID : nil
    }
    let videoComponents = Self.rows(storeService.workspaceDefinition.videoComponents) {
      $0.internalID
    }
    let visions = Self.rows(storeService.workspaceDefinition.visions) { $0.internalID }

    VStack {
      List(selection: $displayedSelection) {
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
              case .createMlImageClassifierVision(let classifierVision):
                Label(classifierVision.displayName, systemImage: "eye")
                  .tag(
                    WorkspaceInspectorSelector(
                      kind: .createMlImageClassifierVision,
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
    .onChange(of: displayedSelection) { _, selection in
      Self.select(
        selection, storeService: storeService, editingState: editingState,
        onBlocked: onSelectionBlocked)
      displayedSelection = storeService.inspectorSelector
    }
    .onChange(of: storeService.inspectorSelector) { _, selection in
      displayedSelection = selection
    }
    .sheet(item: $addSheet) { sheet in
      WorkspaceAddResourceSheet(
        sheet: sheet, draft: $draft, devices: deviceOptions,
        videoComponents: storeService.workspaceDefinition.videoComponents,
        validationMessage: document == nil
          ? "The Workspace document is unavailable."
          : additionFailure
            ?? WorkspaceResourceAddition.validationMessage(
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
    } + deviceRegistry.cameras.map {
      .init(
        id: .avCaptureDevice(uniqueID: $0.id), name: $0.name,
        width: UInt32(exactly: $0.width) ?? 0, height: UInt32(exactly: $0.height) ?? 0)
    }
  }

  var canAddResource: Bool { document != nil && !storeService.isOutputActive }

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
      sheet: sheet, draft: draft, devices: deviceOptions, storeService: storeService,
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
    @Previewable @State var editingState = WorkspaceEditingState()
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState()
    WorkspaceSidebar(
      storeService: storeService, editingState: editingState,
      deviceRegistry: DeviceRegistryService(),
      appletData: WorkspaceAppletData()
    )
    .frame(width: 260, height: 640)
  }
#endif
