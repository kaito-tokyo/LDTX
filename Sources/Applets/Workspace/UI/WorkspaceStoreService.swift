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

  public var definition: WorkspaceDefinition {
    didSet {
      if definition != oldValue { documentContentsDidChange?() }
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
  public var inspectorSelector: WorkspaceInspectorSelector? {
    get { storedInspectorSelector }
    set {
      guard newValue != storedInspectorSelector else { return }
      do {
        try validateInspectorEdits()
        storedInspectorSelector = newValue
        ocrRegionDrafts.removeAll()
      } catch { reportError(error) }
    }
  }
  var ocrRegionDrafts: [UInt64: [String: String]] = [:]
  private var inspectorEditErrors: [UInt64: String] = [:]

  public func validateInspectorEdits() throws {
    if let message = inspectorEditErrors.sorted(by: { $0.key < $1.key }).first?.value {
      throw WorkspaceSelectionError(message: message)
    }
  }

  func editOcrRegion(internalID: UInt64, field: String, text: String) {
    guard !isOutputActive else { return }
    ocrRegionDrafts[internalID, default: [:]][field] = text
    do {
      guard
        let index = definition.visions.firstIndex(where: { $0.ocrVision.internalID == internalID }),
        case .ocrVision(var vision) = definition.visions[index].definition
      else { throw WorkspaceSelectionError(message: "The OCR Vision is no longer available.") }
      var region =
        vision.hasRegionOfInterest
        ? vision.regionOfInterest
        : .with {
          $0.widthRational = .with { $0.set(num: 1, den: 1) }
          $0.heightRational = .with { $0.set(num: 1, den: 1) }
        }
      let fields:
        [(
          String,
          WritableKeyPath<Ldtx_Workspace_V4_VisionRegionOfInterest, Ldtx_Workspace_V4_Rational32>
        )] = [
          ("X", \.xRational), ("Y", \.yRational), ("Width", \.widthRational),
          ("Height", \.heightRational),
        ]
      for (name, path) in fields {
        if let text = ocrRegionDrafts[internalID]?[name] {
          region[keyPath: path] = try RationalParseStrategy().parse(text)
        }
      }
      try WorkspaceV4IntegrityValidator.validateRegionOfInterest(region)
      vision.regionOfInterest = region
      definition.visions[index].definition = .ocrVision(vision)
      inspectorEditErrors.removeValue(forKey: internalID)
    } catch {
      inspectorEditErrors[internalID] =
        "Correct the OCR ROI before leaving this Inspector. " + error.localizedDescription
    }
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
    outputFailureMessage: String? = nil
  ) {
    self.definition = definition
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
    guard !isOutputActive else {
      throw WorkspaceSelectionError(message: "Programs cannot be deleted during output.")
    }
    guard let runtimeActions else {
      throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
    }
    try runtimeActions.removeProgram(internalID: internalID)
  }

  public func selectProgram(internalID: UInt64) throws {
    try validateInspectorEdits()
    guard let runtimeActions else {
      throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
    }
    try runtimeActions.selectProgram(internalID: internalID)
  }

  public func updateProgramRuntimes() {
    runtimeActions?.updateProgramRuntimes()
  }

  public func startOutput() async throws {
    try validateInspectorEdits()
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

  public func captureScreenshots() throws -> [URL] {
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
  @ObservationIgnored public var errorHandler: ((Error) -> Void)?

  public func reportError(_ error: Error) {
    errorHandler?(error)
  }
  public var selectedProgram: Ldtx_Workspace_V4_ProgramDefinition? {
    let id = workspaceURL.map { appletData.state(for: $0).selectedProgramInternalID } ?? nil
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
    _ = try preferences(for: programID, target: target)
    for transform in value.videoLayerTransforms.values {
      try WorkspaceV4IntegrityValidator.validateTransform(transform)
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
    guard let index = self.definition.programs.firstIndex(where: { $0.internalID == programID }),
      self.definition.programs[index][keyPath: target.layerIDs].sorted() == ids.sorted()
    else { throw WorkspaceSelectionError(message: "The video layer order changed.") }
    var definition = self.definition
    definition.programs[index][keyPath: target.layerIDs] = ids
    self.definition = definition
  }
  var videoComponentOptions: [WorkspaceSelectionOption<UInt64>] {
    definition.videoComponents.compactMap { component in
      guard let id = try? WorkspaceV4IntegrityValidator.videoComponentID(component),
        let name = component.displayName
      else { return nil }
      return .init(id: id, name: name)
    }
  }

  func setVideoLayerIncluded(
    _ included: Bool, componentID: UInt64, programID: UInt64, target: WorkspaceCanvasTarget
  ) throws {
    guard !isOutputActive,
      let index = definition.programs.firstIndex(where: { $0.internalID == programID }),
      videoComponentOptions.contains(where: { $0.id == componentID })
    else { throw WorkspaceSelectionError(message: "Video layer membership cannot be changed now.") }
    var ids = definition.programs[index][keyPath: target.layerIDs]
    if included {
      guard !ids.contains(componentID) else { return }
      ids.append(componentID)
    } else {
      guard ids.contains(componentID) else { return }
      ids.removeAll { $0 == componentID }
    }
    var updated = definition
    updated.programs[index][keyPath: target.layerIDs] = ids
    definition = updated
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
      preferences.audioChannelGainsDecibels[id] = try RationalSliderEncoding.encode(
        decibels, denominator: 10)
    } catch {
      reportError(error)
      return false
    }
    updateMixPreferences()
    synchronizeAudioMonitor()
    return true
  }

  public var localState: WorkspaceLocalState {
    workspaceURL.map { appletData.state(for: $0) } ?? .init()
  }
  public var canMonitor: Bool { workspaceURL != nil }
  public func updateMonitor(_ mutation: (inout WorkspaceLocalState) -> Void) {
    guard let workspaceURL else { return }
    appletData.updateState(for: workspaceURL, mutation)
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
