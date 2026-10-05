// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AppKit
import LDTXAppletSupport
import LDTXWorkspaceAppletInterface

public final class WorkspaceContent: NSTabViewController {
  let landscape = VideoLayersEditor()
  let portrait = VideoLayersEditor()
  let audio = AudioMixEditor()
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
    for (title, controller) in [
      ("Landscape", landscape as NSViewController), ("Portrait", portrait), ("Audio Mix", audio),
    ] {
      let item = NSTabViewItem(viewController: controller)
      item.label = title
      addTabViewItem(item)
    }
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
    for (target, editor) in [(WorkspaceCanvasTarget.landscape, landscape), (.portrait, portrait)] {
      let program = selectedProgram
      let preference =
        id.flatMap { uiState.preferences[keyPath: target.preferences][$0] } ?? .init()
      let input = VideoLayersTableInput(
        layerIDs: program?[keyPath: target.layerIDs] ?? [], programPreferences: preference,
        definition: uiState.definition,
        canvasWidth: Double(target.defaultProfile.width),
        canvasHeight: Double(target.defaultProfile.height),
        preferences: { [weak self] in
          guard let self, let id else {
            throw WorkspaceSelectionError(message: "No program selected.")
          }
          return try preferences(for: id, target: target)
        },
        onCommitPreferences: { [weak self] value in
          guard let self, let id else {
            throw WorkspaceSelectionError(message: "No program selected.")
          }
          try commitPreferences(value, programID: id, target: target)
        },
        onCommitLayerOrder: { [weak self] ids in
          guard let self, let id else {
            throw WorkspaceSelectionError(message: "No program selected.")
          }
          try commitLayerOrder(ids, programID: id, target: target)
        },
        onError: { [weak editor] error in
          editor?.errorLabel.stringValue = error.localizedDescription
        })
      editor.commitMembership = { [weak self] ids, expected, candidates in
        guard let self, let id else {
          throw WorkspaceSelectionError(message: "No program selected.")
        }
        try commitVideoLayerMembership(
          ids, expectedIDs: expected, expectedCandidates: candidates, programInternalID: id,
          target: target)
      }
      editor.update(programID: id, input: input, active: uiState.isOutputActive)
      editor.outputErrorLabel.stringValue = uiState.outputFailureMessage ?? ""
      editor.outputErrorLabel.isHidden = uiState.outputFailureMessage == nil
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
    let candidates = VideoLayersEditor.options(in: uiState.definition)
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
  public func stop() {
    landscape.closeManager()
    portrait.closeManager()
    audio.stop()
  }
}
