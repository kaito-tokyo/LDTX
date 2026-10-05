// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AppKit
import LDTXAppletSupport
import LDTXWorkspaceAppletInterface

public final class WorkspaceContent: NSTabViewController {
  let landscape = VideoLayersEditor()
  let portrait = VideoLayersEditor()
  let audio = AudioMixEditor()
  let landscapeStatus = NSTextField(wrappingLabelWithString: "")
  let portraitStatus = NSTextField(wrappingLabelWithString: "")
  private(set) var videoLayerManager: VideoLayersManagementSheet?
  private var managedTarget: WorkspaceCanvasTarget?
  private var displayedProgramID: UInt64?
  let uiState: WorkspaceUIState
  let appletData: WorkspaceAppletData
  private let peakMeter: ProgramAudioPeakMeter
  private weak var dispatcher: (any WorkspaceDispatcherProtocol)?
  private var documentReference: DocumentReference?
  private var workspaceURL: URL? {
    guard let document = documentReference?.document else { return nil }
    return document.fileURL ?? uiState.localStateURL
  }
  var selectedProgram: Ldtx_Workspace_V4_ProgramDefinition? {
    let id = workspaceURL.map { appletData.state(for: $0).selectedProgramInternalID } ?? nil
    return uiState.definition.programs.first { $0.internalID == id }
      ?? uiState.definition.programs.first
  }

  public init(
    uiState: WorkspaceUIState, appletData: WorkspaceAppletData,
    audioPeakMeter: ProgramAudioPeakMeter
  ) {
    self.uiState = uiState
    self.appletData = appletData
    self.peakMeter = audioPeakMeter
    super.init(nibName: nil, bundle: nil)
    for (title, editor, status) in [
      ("Landscape", landscape, landscapeStatus), ("Portrait", portrait, portraitStatus),
    ] {
      let controller = NSViewController()
      controller.view = NSView()
      controller.addChild(editor)
      let stack = contentStack([editor.view, status])
      pinContent(stack, in: controller.view, inset: 0)
      editor.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      status.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
      status.isHidden = true
      let item = NSTabViewItem(viewController: controller)
      item.label = title
      addTabViewItem(item)
    }
    let audioItem = NSTabViewItem(viewController: audio)
    audioItem.label = "Audio Mix"
    addTabViewItem(audioItem)
    selectedTabViewItemIndex = 0
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  public func connect(
    dispatcher: any WorkspaceDispatcherProtocol, documentReference: DocumentReference
  ) {
    self.dispatcher = dispatcher
    self.documentReference = documentReference
    audio.content = self
    refresh()
    dispatcher.synchronizeAudioMonitor()
  }

  public func refresh() {
    let id = selectedProgram?.internalID
    if displayedProgramID != id {
      closeVideoLayerManager()
      landscape.table.removeAllRows()
      portrait.table.removeAllRows()
      displayedProgramID = id
    }
    if uiState.isOutputActive { closeVideoLayerManager() }
    for (target, editor, status) in [
      (WorkspaceCanvasTarget.landscape, landscape, landscapeStatus),
      (.portrait, portrait, portraitStatus),
    ] {
      let program = selectedProgram
      let preference =
        id.flatMap { uiState.preferences[keyPath: target.preferences][$0] } ?? .init()
      let layerIDs = program?[keyPath: target.layerIDs] ?? []
      editor.update(
        definition: uiState.definition, programPreferences: preference, layerIDs: layerIDs,
        canvasWidth: Double(target.defaultProfile.width),
        canvasHeight: Double(target.defaultProfile.height),
        onCommitTransform: { [weak self] layerID, value in
          guard let self, let id else {
            throw WorkspaceSelectionError(message: "No program selected.")
          }
          return try commitVideoLayerTransform(
            value, layerID: layerID, programID: id, target: target)
        },
        onSetHidden: { [weak self] layerID, value in
          guard let self, let id else {
            throw WorkspaceSelectionError(message: "No program selected.")
          }
          var updated = try preferences(for: id, target: target)
          updated.videoLayerHidden[layerID] = value
          try commitPreferences(updated, programID: id, target: target)
        },
        onCommitLayerOrder: { [weak self] ids in
          guard let self, let id else {
            throw WorkspaceSelectionError(message: "No program selected.")
          }
          try commitLayerOrder(ids, programID: id, target: target)
        },
        onError: { [weak status] error in
          status?.textColor = .systemRed
          status?.stringValue = error.localizedDescription
          status?.isHidden = false
        })
      editor.manageButton.invoke = { [weak self] in self?.openVideoLayerManager(target: target) }
      editor.manageButton.isEnabled = id != nil && !uiState.isOutputActive
      status.textColor = .secondaryLabelColor
      status.stringValue =
        uiState.outputFailureMessage
        ?? (id == nil ? "No program selected" : layerIDs.isEmpty ? "No video layers" : "")
      status.isHidden = status.stringValue.isEmpty
      if managedTarget?.preferences == target.preferences {
        videoLayerManager?.update(
          ids: layerIDs, options: VideoLayersManagementSheet.options(in: uiState.definition),
          active: uiState.isOutputActive)
      }
    }
    audio.refresh(peakMeter: peakMeter)
    audio.outputErrorLabel.stringValue = uiState.outputFailureMessage ?? ""
    audio.outputErrorLabel.isHidden = uiState.outputFailureMessage == nil
  }

  func preferences(for id: UInt64, target: WorkspaceCanvasTarget) throws
    -> Ldtx_Workspace_V4_ProgramPreferences
  {
    guard uiState.definition.programs.contains(where: { $0.internalID == id }) else {
      throw WorkspaceSelectionError(message: "The Program is unavailable.")
    }
    return uiState.preferences[keyPath: target.preferences][id] ?? .init()
  }
  func commitVideoLayerTransform(
    _ value: Ldtx_Workspace_V4_BasicTransform, layerID: UInt64,
    programID: UInt64, target: WorkspaceCanvasTarget
  ) throws -> Ldtx_Workspace_V4_BasicTransform {
    var updated = try preferences(for: programID, target: target)
    var transform = updated.videoLayerTransforms[layerID] ?? .init()
    transform.translationX = value.translationX
    transform.translationY = value.translationY
    transform.scaleX = value.scaleX
    transform.scaleY = value.scaleY
    updated.videoLayerTransforms[layerID] = transform
    try commitPreferences(updated, programID: programID, target: target)
    return transform
  }

  func commitPreferences(
    _ value: Ldtx_Workspace_V4_ProgramPreferences, programID: UInt64, target: WorkspaceCanvasTarget
  ) throws {
    _ = try preferences(for: programID, target: target)
    guard
      value.videoLayerTransforms.values.allSatisfy({ transform in
        [
          transform.translationX, transform.translationY, transform.scaleX, transform.scaleY,
          transform.topInset, transform.rightInset, transform.bottomInset, transform.leftInset,
        ].allSatisfy(\.isFinite)
      })
    else { throw WorkspaceSelectionError(message: "Invalid transform.") }
    var candidate = uiState.preferences
    candidate[keyPath: target.preferences][programID] = value
    uiState.preferences = candidate
    dispatcher?.updateMixPreferences()
    dispatcher?.synchronizeAudioMonitor()
    refresh()
  }
  func commitLayerOrder(_ ids: [UInt64], programID: UInt64, target: WorkspaceCanvasTarget) throws {
    guard let index = uiState.definition.programs.firstIndex(where: { $0.internalID == programID }),
      uiState.definition.programs[index][keyPath: target.layerIDs].sorted() == ids.sorted()
    else { throw WorkspaceSelectionError(message: "The video layer order changed.") }
    var definition = uiState.definition
    definition.programs[index][keyPath: target.layerIDs] = ids
    uiState.definition = definition
    refresh()
  }
  func commitVideoLayerMembership(
    _ ids: [UInt64], expectedIDs: [UInt64], expectedCandidates: [WorkspaceSelectionOption<UInt64>],
    programInternalID: UInt64, target: WorkspaceCanvasTarget
  ) throws {
    guard !uiState.isOutputActive,
      let index = uiState.definition.programs.firstIndex(where: {
        $0.internalID == programInternalID
      })
    else { throw WorkspaceSelectionError(message: "Video layers cannot be managed now.") }
    let current = uiState.definition.programs[index][keyPath: target.layerIDs]
    let candidates = VideoLayersManagementSheet.options(in: uiState.definition)
    guard current == expectedIDs, candidates == expectedCandidates else {
      throw WorkspaceSelectionError(message: "Video layers changed. Reopen this sheet.")
    }
    guard Set(ids).count == ids.count,
      ids.allSatisfy({ id in current.contains(id) || candidates.contains(where: { $0.id == id }) })
    else { throw WorkspaceSelectionError(message: "Select available video layers.") }
    var definition = uiState.definition
    definition.programs[index][keyPath: target.layerIDs] = ids
    uiState.definition = definition
    refresh()
  }
  @discardableResult
  func updateAudio(
    target: WorkspaceCanvasTarget, mutation: (inout Ldtx_Workspace_V4_ProgramPreferences) -> Void
  ) -> Bool {
    guard let id = selectedProgram?.internalID else { return false }
    do {
      var updated = try preferences(for: id, target: target)
      mutation(&updated)
      try commitPreferences(updated, programID: id, target: target)
      audio.errorLabel.stringValue = ""
      return true
    } catch {
      audio.errorLabel.stringValue = error.localizedDescription
      return false
    }
  }
  var localState: WorkspaceLocalState { workspaceURL.map { appletData.state(for: $0) } ?? .init() }
  var canMonitor: Bool { workspaceURL != nil }
  func updateMonitor(_ mutation: (inout WorkspaceLocalState) -> Void) {
    guard let workspaceURL else { return }
    appletData.updateState(for: workspaceURL, mutation)
    dispatcher?.synchronizeAudioMonitor()
    refresh()
  }
  func selectAudioMix(_ portrait: Bool) {
    uiState.selectedAudioMix = portrait ? .portrait : .landscape
    refresh()
  }
  func openVideoLayerManager(target: WorkspaceCanvasTarget) {
    guard !uiState.isOutputActive, videoLayerManager == nil,
      let program = selectedProgram, let window = view.window
    else { return }
    let sheet = VideoLayersManagementSheet(
      ids: program[keyPath: target.layerIDs],
      options: VideoLayersManagementSheet.options(in: uiState.definition))
    sheet.commit = { [weak self] ids, baseline, candidates in
      guard let self else { throw WorkspaceSelectionError(message: "Workspace is unavailable.") }
      try commitVideoLayerMembership(
        ids, expectedIDs: baseline, expectedCandidates: candidates,
        programInternalID: program.internalID, target: target)
    }
    sheet.onClose = { [weak self] in self?.closeVideoLayerManager() }
    videoLayerManager = sheet
    managedTarget = target
    window.beginSheet(sheet.window!)
  }

  func closeVideoLayerManager() {
    guard let manager = videoLayerManager else { return }
    if let window = manager.window, let parent = window.sheetParent { parent.endSheet(window) }
    manager.window?.orderOut(nil)
    videoLayerManager = nil
    managedTarget = nil
  }

  public func stop() {
    closeVideoLayerManager()
    audio.stop()
  }
}
