// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
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
    workspace.definition.definition.inputDevices.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(workspace.definition.definition)
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
    workspace.definition.definition.inputDevices.append(wrapper)
    try WorkspaceV4IntegrityValidator.validate(workspace.definition.definition)
    return internalID
  }

  @discardableResult
  public func addProgram(displayName: String) throws -> UInt64 {
    let internalID = internalIDGenerator.next()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = internalID
    program.displayName = displayName
    workspace.definition.definition.programs.append(program)
    try WorkspaceV4IntegrityValidator.validate(workspace.definition.definition)
    return internalID
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
