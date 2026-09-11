// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import Observation

/// Generates Workspace-local IDs using the Version 4 bit allocation.
@MainActor
public final class WorkspaceInternalIDGenerator {
  private var randomNumberGenerator = SystemRandomNumberGenerator()

  public init() {}

  /// Returns an ID with a zero sign bit, Unix milliseconds in bits 62...15,
  /// and uniformly random data in bits 14...0.
  public func next(now: Date = Date()) -> UInt64 {
    let milliseconds = UInt64(max(0, now.timeIntervalSince1970 * 1_000))
    let timestamp = (milliseconds & 0x0000_FFFF_FFFF_FFFF) << 15
    let random = UInt64.random(in: 0 ... 0x7fff, using: &randomNumberGenerator)
    return timestamp | random
  }
}

/// The Version 4 Workspace state that is authoritative while an app session is
/// open. It stores generated protobuf messages directly and never converts to
/// Version 3 models.
@MainActor
@Observable
public final class WorkspaceV4Store {
  public private(set) var workspace: WorkspaceV4Package
  private var lastSavedDefinitionData: Data
  private var lastSavedPreferencesData: Data
  private let internalIDGenerator: WorkspaceInternalIDGenerator

  public init(
    workspace: WorkspaceV4Package,
    internalIDGenerator: WorkspaceInternalIDGenerator = WorkspaceInternalIDGenerator()
  ) throws {
    self.workspace = workspace
    self.internalIDGenerator = internalIDGenerator
    lastSavedDefinitionData = try WorkspaceV4PersistenceCodec.encodeDefinition(workspace.definition)
    lastSavedPreferencesData = try WorkspaceV4PersistenceCodec.encodePreferences(workspace.preferences)
  }

  public convenience init(cleanNamed displayName: String) throws {
    let definition = WorkspaceV4DefinitionDocument(
      externalID: WorkspaceV4PersistenceCodec.makeExternalID(),
      definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
        $0.displayName = displayName
        $0.canvasConfiguration.landscapeProfileID = "sdr-landscape-1080p60"
        $0.canvasConfiguration.portraitProfileID = "sdr-portrait-1080p60"
        $0.canvasConfiguration.frameRate = 60
        $0.canvasConfiguration.landscapeVideoBitRate = 6_000_000
        $0.canvasConfiguration.portraitVideoBitRate = 6_000_000
      }
    )
    let preferences = WorkspaceV4PreferencesDocument(
      externalID: WorkspaceV4PersistenceCodec.makeExternalID(),
      preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4()
    )
    try self.init(workspace: WorkspaceV4Package(definition: definition, preferences: preferences))
  }

  public var isDirty: Bool {
    guard
      let definitionData = try? WorkspaceV4PersistenceCodec.encodeDefinition(workspace.definition),
      let preferencesData = try? WorkspaceV4PersistenceCodec.encodePreferences(workspace.preferences)
    else { return true }
    return definitionData != lastSavedDefinitionData || preferencesData != lastSavedPreferencesData
  }

  public func editDefinition(
    _ mutation: (inout Ldtx_Workspace_V4_WorkspaceDefinitionV4) -> Void
  ) {
    mutation(&workspace.definition.definition)
  }

  public func editPreferences(
    _ mutation: (inout Ldtx_Workspace_V4_WorkspacePreferencesV4) -> Void
  ) {
    mutation(&workspace.preferences.preferences)
  }

  @discardableResult
  public func addVideoInputDevice(displayName: String) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var device = Ldtx_Workspace_V4_VideoInputDevice()
    device.internalID = internalID
    device.displayName = displayName
    var wrapper = Ldtx_Workspace_V4_InputDeviceWrapper()
    wrapper.videoDevice = device
    var definition = workspace.definition.definition
    definition.inputDevices.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addAudioInputDevice(displayName: String) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var device = Ldtx_Workspace_V4_AudioInputDevice()
    device.internalID = internalID
    device.displayName = displayName
    var wrapper = Ldtx_Workspace_V4_InputDeviceWrapper()
    wrapper.audioDevice = device
    var definition = workspace.definition.definition
    definition.inputDevices.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addProgram(displayName: String) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = internalID
    program.displayName = displayName
    var definition = workspace.definition.definition
    definition.programs.append(program)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addVFXSource(
    displayName: String,
    inputDeviceInternalID: UInt64
  ) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_VfxSourceComponent()
    component.internalID = internalID
    component.displayName = displayName
    component.inputDeviceInternalID = inputDeviceInternalID
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.vfxSource = component
    var definition = workspace.definition.definition
    definition.videoComponents.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addSolidColorFill(
    displayName: String,
    color: Ldtx_Workspace_V4_ExtendedSrgbColor = .init()
  ) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_FillSolidColorComponent()
    component.internalID = internalID
    component.displayName = displayName
    component.color = color
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.solidColorFill = component
    var definition = workspace.definition.definition
    definition.videoComponents.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  @discardableResult
  public func addOcrVision(
    displayName: String,
    inputDeviceInternalID: UInt64,
    intervalSeconds: Double = 5
  ) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var trigger = Ldtx_Workspace_V4_IntervalVisionTrigger()
    trigger.intervalSeconds = intervalSeconds
    var triggerWrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
    triggerWrapper.intervalTrigger = trigger
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.internalID = internalID
    vision.displayName = displayName
    vision.inputDeviceInternalID = inputDeviceInternalID
    vision.triggers = [triggerWrapper]
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.ocrVision = vision
    var definition = workspace.definition.definition
    definition.visions.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
    return internalID
  }

  public func removeVideoLayer(internalID: UInt64) throws {
    var definition = workspace.definition.definition
    definition.inputDevices.removeAll {
      (try? WorkspaceV4IntegrityValidator.inputDeviceID($0)) == internalID
    }
    definition.videoComponents.removeAll {
      (try? WorkspaceV4IntegrityValidator.videoComponentID($0)) == internalID
    }
    guard definition.inputDevices.count != workspace.definition.definition.inputDevices.count
      || definition.videoComponents.count != workspace.definition.definition.videoComponents.count
    else { throw WorkspaceV4StoreError.missingVideoLayer(internalID) }
    for index in definition.programs.indices {
      definition.programs[index].landscapeVideoLayerInternalIds.removeAll { $0 == internalID }
      definition.programs[index].portraitVideoLayerInternalIds.removeAll { $0 == internalID }
    }
    try WorkspaceV4IntegrityValidator.validate(WorkspaceV4Package(
      definition: WorkspaceV4DefinitionDocument(
        externalID: workspace.definition.externalID, definition: definition),
      preferences: workspace.preferences))
    workspace.definition.definition = definition
  }

  public func setVideoLayerOrder(
    _ layerInternalIDs: [UInt64],
    forProgramInternalID programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    var definition = workspace.definition.definition
    guard let index = definition.programs.firstIndex(
      where: { $0.internalID == programInternalID })
    else { throw WorkspaceV4StoreError.missingProgram(programInternalID) }
    switch role {
    case .landscape:
      definition.programs[index].landscapeVideoLayerInternalIds = layerInternalIDs
    case .portrait:
      definition.programs[index].portraitVideoLayerInternalIds = layerInternalIDs
    }
    try WorkspaceV4IntegrityValidator.validate(definition)
    workspace.definition.definition = definition
  }

  public func setBasicTransform(
    _ transform: Ldtx_Workspace_V4_BasicTransform,
    forVideoLayerInternalID layerInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    guard workspace.definition.definition.programs.contains(where: { $0.internalID == programInternalID })
    else { throw WorkspaceV4StoreError.missingProgram(programInternalID) }
    editPreferences { preferences in
      var preference = preferences.programPreferences[programInternalID] ?? .init()
      switch role {
      case .landscape: preference.landscapeVideoLayerTransforms[layerInternalID] = transform
      case .portrait: preference.portraitVideoLayerTransforms[layerInternalID] = transform
      }
      preferences.programPreferences[programInternalID] = preference
    }
  }

  /// Replaces both persisted V4 documents as one coherent runtime state.
  public func replace(with workspace: WorkspaceV4Package) {
    self.workspace = workspace
  }

  public func markSaved() throws {
    lastSavedDefinitionData = try WorkspaceV4PersistenceCodec.encodeDefinition(workspace.definition)
    lastSavedPreferencesData = try WorkspaceV4PersistenceCodec.encodePreferences(workspace.preferences)
  }
}

public enum WorkspaceV4StoreError: Error, Equatable, Sendable {
  case missingVideoLayer(UInt64)
  case missingProgram(UInt64)
}
