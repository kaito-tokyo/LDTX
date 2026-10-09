// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAppletSupport
import LDTXProtos
import LDTXWorkspaceAppletInterface
import Observation

@MainActor
@Observable
public final class WorkspaceStoreService {
  public typealias WorkspaceDefinition = Ldtx_Workspace_V4_WorkspaceDefinitionV4
  public typealias VideoComponentWrapper = Ldtx_Workspace_V4_VideoComponentWrapper
  public typealias WorkspacePreferences = Ldtx_Workspace_V4_WorkspacePreferencesV4

  private var storedDefinition: WorkspaceDefinition
  public var definition: WorkspaceDefinition {
    get { storedDefinition }
    set {
      guard !isOutputActive, newValue != storedDefinition else { return }
      storedDefinition = newValue
      documentContentsDidChange?()
    }
  }
  private var storedOutputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4
  public var outputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4 {
    get { storedOutputSettings }
    set {
      guard !isOutputActive, newValue != storedOutputSettings else { return }
      storedOutputSettings = newValue
      documentContentsDidChange?()
    }
  }
  public var preferences: WorkspacePreferences {
    didSet { if preferences != oldValue { documentContentsDidChange?() } }
  }

  @ObservationIgnored public var documentContentsDidChange: (() -> Void)?
  public var externalID: String?
  public var localStateURL: URL?

  public var selectedAudioMix: ProgramAudioPeakMeter.Master = .landscape

  private var storedInspectorSelector: WorkspaceInspectorSelector?
  public var isInspectorVisible = true
  @ObservationIgnored public var pendingEditsDidBlockSelection: (() -> Void)?

  public var inspectorSelector: WorkspaceInspectorSelector? {
    get { storedInspectorSelector }
    set {
      guard newValue != storedInspectorSelector else { return }
      refreshUnconfirmedChanges()
      guard !hasUnconfirmedChanges else {
        pendingEditsDidBlockSelection?()
        return
      }
      storedInspectorSelector = newValue
    }
  }
  private struct EditValidator {
    var hasChanges: () -> Bool
    var validate: () throws -> Void
    var submit: () throws -> Void
  }

  @ObservationIgnored private var contentEditValidators: [EditValidator] = []
  @ObservationIgnored private var inspectorEditValidators: [UUID: EditValidator] = [:]
  public private(set) var hasUnconfirmedChanges = false
  private var storedHasPendingSubmit = false
  public var hasPendingSubmit: Bool {
    get { storedHasPendingSubmit }
    set {
      if newValue { refreshUnconfirmedChanges() }
      guard !newValue || (hasUnconfirmedChanges && !isOutputActive) else { return }
      storedHasPendingSubmit = newValue
    }
  }

  func registerContentEditValidator(
    hasChanges: @escaping () -> Bool = { false },
    submit: @escaping () throws -> Void = {},
    _ validate: @escaping () throws -> Void
  ) {
    contentEditValidators.append(.init(hasChanges: hasChanges, validate: validate, submit: submit))
    refreshUnconfirmedChanges()
  }

  func registerInspectorEditValidator(
    id: UUID, hasChanges: @escaping () -> Bool = { false },
    submit: @escaping () throws -> Void = {},
    _ validate: @escaping () throws -> Void
  ) {
    inspectorEditValidators[id] = .init(hasChanges: hasChanges, validate: validate, submit: submit)
    refreshUnconfirmedChanges()
  }

  func removeInspectorEditValidator(id: UUID) {
    inspectorEditValidators.removeValue(forKey: id)
    refreshUnconfirmedChanges()
  }

  public func refreshUnconfirmedChanges() {
    hasUnconfirmedChanges =
      contentEditValidators.contains { $0.hasChanges() }
      || inspectorEditValidators.values.contains { $0.hasChanges() }
  }

  public func validateInspectorEdits() throws {
    for entry in contentEditValidators { try entry.validate() }
    for entry in inspectorEditValidators.values { try entry.validate() }
  }

  public func requireConfirmedEdits() throws {
    refreshUnconfirmedChanges()
    try validateInspectorEdits()
    guard !hasUnconfirmedChanges else {
      throw WorkspaceSelectionError(message: "Apply the pending edits before switching views.")
    }
  }

  // The Window is the only consumer. Validate every owner before invoking any writeback.
  public func submitPendingEdits() {
    guard hasPendingSubmit else { return }
    defer {
      hasPendingSubmit = false
      refreshUnconfirmedChanges()
    }
    guard !isOutputActive else { return }
    let entries = contentEditValidators + Array(inspectorEditValidators.values)
    let pending = entries.filter { $0.hasChanges() }
    do {
      for entry in pending { try entry.validate() }
      for entry in pending { try entry.submit() }
    } catch { reportInputValidationError(error) }
  }

  @ObservationIgnored public var documentOutputStateDidChange: (() -> Void)?
  public var isOutputActive = false {
    didSet { if isOutputActive != oldValue { documentOutputStateDidChange?() } }
  }
  public var recordingState: WorkspaceRecordingState = .idle
  public var isLocalRecording = false
  public var outputFailureMessage: String?
  public var visionResults: [UInt64: String] = [:]
  public var visionFailureMessages: [UInt64: String] = [:]

  public init(
    definition: WorkspaceDefinition,
    preferences: WorkspacePreferences,
    inspectorSelector: WorkspaceInspectorSelector? = nil,
    isOutputActive: Bool = false,
    isLocalRecording: Bool = false,
    outputFailureMessage: String? = nil,
    outputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4 = .init()
  ) {
    self.storedDefinition = definition
    self.storedOutputSettings = outputSettings
    self.preferences = preferences
    self.inspectorSelector = inspectorSelector
    self.isOutputActive = isOutputActive
    self.isLocalRecording = isLocalRecording
    self.outputFailureMessage = outputFailureMessage
  }

  @ObservationIgnored public weak var runtimeActions: (any WorkspaceRuntimeActions)?
  @ObservationIgnored public var documentReference: DocumentReference?
  public var workspaceURL: URL? {
    guard let document = documentReference?.document else { return nil }
    return document.fileURL ?? localStateURL
  }
  @ObservationIgnored public var appletData = WorkspaceAppletData()
  @ObservationIgnored public var audioPeakMeter = ProgramAudioPeakMeter()

  public func synchronizeVision() {
    runtimeActions?.synchronizeVision()
  }

  public func synchronizeAudioMonitor() {
    runtimeActions?.synchronizeAudioMonitor()
  }

  public func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    guard let runtimeActions else {
      completionHandler([])
      return
    }
    runtimeActions.synchronizeCaptureInputs(
      availableCameraIDs: availableCameraIDs, completionHandler: completionHandler)
  }

  public func renameProgram(internalID: UInt64, name: String) throws {
    guard !isOutputActive else {
      throw WorkspaceSelectionError(message: "Programs cannot be edited during output.")
    }
    guard let index = definition.programs.firstIndex(where: { $0.internalID == internalID }) else {
      throw WorkspaceSelectionError(message: "The Program is no longer available.")
    }
    let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var otherResources = definition
    otherResources.programs.remove(at: index)
    guard !candidate.isEmpty,
      !WorkspaceResourceAddition.existingNames(otherResources).contains(candidate)
    else {
      throw WorkspaceSelectionError(message: "Enter a unique, nonempty Program name.")
    }
    definition.programs[index].displayName = candidate
    updateProgramRuntimes()
  }

  public func removeProgram(internalID: UInt64) throws {
    try requireConfirmedEdits()
    guard !isOutputActive else {
      throw WorkspaceSelectionError(message: "Programs cannot be deleted during output.")
    }
    guard let runtimeActions else {
      throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
    }
    try runtimeActions.removeProgram(internalID: internalID)
    documentContentsDidChange?()
  }

  public func selectProgram(internalID: UInt64) throws {
    if selectedProgram?.internalID != internalID { try requireConfirmedEdits() }
    guard let runtimeActions else {
      throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
    }
    try runtimeActions.selectProgram(internalID: internalID)
  }

  public func updateProgramRuntimes() {
    runtimeActions?.updateProgramRuntimes()
  }

  public func startOutput() async throws {
    try requireConfirmedEdits()
    guard let runtimeActions else {
      throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
    }
    try await runtimeActions.startOutput()
  }

  public func pauseOutput() async {
    await runtimeActions?.pauseOutput()
  }

  public func stopOutput() async {
    await runtimeActions?.stopOutput()
  }

  public func updateMixPreferences() {
    runtimeActions?.updateMixPreferences()
  }

  public func captureScreenshots() throws -> [WorkspaceScreenshot] {
    guard let runtimeActions else {
      throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
    }
    return try runtimeActions.captureScreenshots()
  }

  public func openScreenshotsDirectory() {
    runtimeActions?.openScreenshotsDirectory()
  }

  public func validateForSaving() throws {
    try validateInspectorEdits()
    try Self.validateForSaving(WorkspaceV4Bundle(definition: definition, preferences: preferences))
  }

  public nonisolated static func validateForSaving(_ workspace: WorkspaceV4Bundle) throws {
    let issues = WorkspaceV4IntegrityValidator.validationIssues(in: workspace)
    guard issues.isEmpty else {
      throw WorkspaceSaveValidationError(
        messages: issues.map { "\($0.context): \($0.error.localizedDescription)" })
    }
  }
  @ObservationIgnored public var inputValidationErrorHandler: ((Error) -> Void)?

  public func reportInputValidationError(_ error: Error) {
    inputValidationErrorHandler?(error)
  }

  @ObservationIgnored public var errorHandler: ((Error) -> Void)?

  public static func isInputValidationError(_ error: Error) -> Bool {
    error is WorkspaceSelectionError || error is RationalInputError
      || error is Rational32EncodingError || error is WorkspaceSaveValidationError
      || error is WorkspaceV4IntegrityError
  }

  public func reportError(_ error: Error) {
    if Self.isInputValidationError(error) {
      reportInputValidationError(error)
    } else {
      errorHandler?(error)
    }
  }
  public var selectedProgram: Ldtx_Workspace_V4_ProgramDefinition? {
    let id =
      (documentReference?.document?.fileURL ?? localStateURL)
      .map { appletData.state(for: $0).selectedProgramInternalID } ?? nil
    return definition.programs.first { $0.internalID == id } ?? definition.programs.first
  }
  public func preferences(for id: UInt64, target: WorkspaceCanvasTarget) throws
    -> Ldtx_Workspace_V4_ProgramPreferences
  {
    guard self.definition.programs.contains(where: { $0.internalID == id }) else {
      throw WorkspaceSelectionError(message: "The Program is unavailable.")
    }
    return self.preferences[keyPath: target.preferences][id] ?? .init()
  }
  public func commitVideoLayerTransform(
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

  public func commitPreferences(
    _ value: Ldtx_Workspace_V4_ProgramPreferences, programID: UInt64, target: WorkspaceCanvasTarget
  ) throws {
    let current = try preferences(for: programID, target: target)
    guard
      !isOutputActive
        || current.videoLayerInternalIds.sorted() == value.videoLayerInternalIds.sorted()
    else { throw WorkspaceSelectionError(message: "Video layer membership cannot be changed now.") }
    for transform in value.videoLayerTransforms.values {
      try WorkspaceV4IntegrityValidator.validateTransform(transform)
    }
    var value = value
    if value.hasAudioMasterVolumeDecibels {
      value.audioMasterVolumeDecibels = try Rational32DecibelEncoding.encode(
        value.audioMasterVolumeDecibels.double)
    }
    var candidate = self.preferences
    candidate[keyPath: target.preferences][programID] = value
    self.preferences = candidate
    self.updateMixPreferences()
    self.synchronizeAudioMonitor()
  }
  public func commitLayerOrder(_ ids: [UInt64], programID: UInt64, target: WorkspaceCanvasTarget)
    throws
  {
    var updated = try preferences(for: programID, target: target)
    guard updated.videoLayerInternalIds.sorted() == ids.sorted()
    else { throw WorkspaceSelectionError(message: "The video layer order changed.") }
    updated.videoLayerInternalIds = ids
    try commitPreferences(updated, programID: programID, target: target)
  }

  var videoComponentOptions: [WorkspaceSelectionOption<UInt64>] {
    definition.videoComponents.compactMap { component in
      guard let id = component.internalID,
        let name = component.displayName
      else { return nil }
      return .init(id: id, name: name)
    }
  }

  func setVideoLayerIncluded(
    _ included: Bool, componentID: UInt64, programID: UInt64, target: WorkspaceCanvasTarget
  ) throws {
    guard !isOutputActive,
      definition.programs.contains(where: { $0.internalID == programID }),
      videoComponentOptions.contains(where: { $0.id == componentID })
    else { throw WorkspaceSelectionError(message: "Video layer membership cannot be changed now.") }
    var updated = try preferences(for: programID, target: target)
    var ids = updated.videoLayerInternalIds
    if included {
      guard !ids.contains(componentID) else { return }
      ids.append(componentID)
    } else {
      guard ids.contains(componentID) else { return }
      ids.removeAll { $0 == componentID }
    }
    updated.videoLayerInternalIds = ids
    try commitPreferences(updated, programID: programID, target: target)
  }

  @discardableResult
  public func updateAudio(
    target: WorkspaceCanvasTarget, mutation: (inout Ldtx_Workspace_V4_ProgramPreferences) -> Void
  ) -> Bool {
    guard let id = selectedProgram?.internalID else {
      reportError(WorkspaceSelectionError(message: "No Program is selected."))
      return false
    }
    do {
      var updated = try preferences(for: id, target: target)
      mutation(&updated)
      try commitPreferences(updated, programID: id, target: target)
      return true
    } catch {
      reportError(error)
      return false
    }
  }
  @discardableResult
  public func setAudioChannelGain(_ decibels: Double, forAudioInputDeviceInternalID id: UInt64)
    -> Bool
  {
    guard definition.audioDevices.contains(where: { $0.internalID == id }) else {
      reportError(WorkspaceSelectionError(message: "The audio device is no longer available."))
      return false
    }
    do {
      preferences.audioChannelGainsDecibels[id] = try Rational32DecibelEncoding.encode(decibels)
    } catch {
      reportError(error)
      return false
    }
    updateMixPreferences()
    synchronizeAudioMonitor()
    return true
  }

  public var localState: WorkspaceLocalState {
    var state = workspaceURL.map { appletData.state(for: $0) } ?? .init()
    if let id = externalID.flatMap(UUID.init(uuidString:)) {
      state.recordingFolderPath = appletData.recordingFolderPaths[id]
      state.landscapeYouTubeLiveStreamID = appletData.landscapeYouTubeLiveStreamIDs[id]
      state.portraitYouTubeLiveStreamID = appletData.portraitYouTubeLiveStreamIDs[id]
    }
    return state
  }
  public var canMonitor: Bool { workspaceURL != nil }
  public func updateMonitor(_ mutation: (inout WorkspaceLocalState) -> Void) {
    guard let workspaceURL else { return }
    var updated = localState
    mutation(&updated)
    do {
      if let volume = updated.monitorVolume {
        updated.monitorVolume = try Rational32DecibelEncoding.encode(volume).double
      }
    } catch {
      reportError(error)
      return
    }
    updated.recordingFolderPath = nil
    updated.landscapeYouTubeLiveStreamID = nil
    updated.portraitYouTubeLiveStreamID = nil
    appletData.updateState(for: workspaceURL) { $0 = updated }
    self.synchronizeAudioMonitor()
  }
  public func selectAudioMix(_ portrait: Bool) {
    self.selectedAudioMix = portrait ? .portrait : .landscape
  }

}

public struct WorkspaceSaveValidationError: LocalizedError, Sendable {
  public let messages: [String]

  public var errorDescription: String? { "The Workspace could not be saved." }
  public var failureReason: String? { messages.joined(separator: "\n\n") }
  public var recoverySuggestion: String? {
    messages.joined(separator: "\n\n") + "\n\nCorrect these settings and save again."
  }
}
