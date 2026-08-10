// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

public struct WorkspacePersistenceSnapshot: @unchecked Sendable {
    public let definition: WorkspaceDefinition
    public let preferences: WorkspacePreferences
    public let protobufData: Data
    public let revision: UInt64
}

@MainActor
@Observable
public final class WorkspaceStore {
    public private(set) var definition: WorkspaceDefinition
    public private(set) var preferences: WorkspacePreferences

    @ObservationIgnored
    private var lastSavedBytes: Data

    @ObservationIgnored
    private var lastSavedPreferences: WorkspacePreferences

    @ObservationIgnored
    private var currentProtobufBytes: Data?

    @ObservationIgnored
    private var revision: UInt64 = 0

    @ObservationIgnored
    private var lastSavedRevision: UInt64 = 0

    public var isDirty: Bool {
        guard let currentProtobufBytes else {
            return true
        }
        return currentProtobufBytes != lastSavedBytes || preferences != lastSavedPreferences
    }

    public init(
        definition: WorkspaceDefinition,
        preferences: WorkspacePreferences = WorkspacePreferences(),
        lastSavedBytes: Data
    ) {
        self.definition = definition
        self.preferences = preferences
        self.lastSavedBytes =
            (try? WorkspacePersistenceCodec.normalizeWorkspaceProtobuf(lastSavedBytes))
            ?? lastSavedBytes
        self.lastSavedPreferences = preferences
        currentProtobufBytes = try? WorkspacePersistenceCodec.encodeWorkspace(definition)
    }

    public convenience init(
        snapshot: WorkspaceSnapshot,
        lastSavedBytes: Data
    ) {
        self.init(
            definition: snapshot.definition,
            preferences: snapshot.preferences,
            lastSavedBytes: lastSavedBytes
        )
    }

    public convenience init(clean definition: WorkspaceDefinition) throws {
        try self.init(
            definition: definition,
            lastSavedBytes: WorkspacePersistenceCodec.encodeWorkspace(definition)
        )
    }

    public var savedProtobufBytes: Data {
        lastSavedBytes
    }

    public func edit(_ mutation: (inout WorkspaceDefinition) -> Void) {
        mutation(&definition)
        noteDefinitionChanged()
    }

    public func editPreferences(_ mutation: (inout WorkspacePreferences) -> Void) {
        mutation(&preferences)
        revision &+= 1
    }

    public func replacePreferences(_ preferences: WorkspacePreferences) {
        guard self.preferences != preferences else { return }
        self.preferences = preferences
        revision &+= 1
    }

    public func replaceDefinition(_ definition: WorkspaceDefinition) {
        self.definition = definition
        noteDefinitionChanged()
    }

    /// Replaces the persisted Workspace state as one consistent pair.
    ///
    /// Operations such as a Workspace-wide rename rewrite references in both
    /// the definition and preferences. Publishing either half independently
    /// would expose an inconsistent state to observers.
    public func replace(with snapshot: WorkspaceSnapshot) {
        definition = snapshot.definition
        preferences = snapshot.preferences
        noteDefinitionChanged()
    }

    public func markSaved() throws {
        let bytes = try WorkspacePersistenceCodec.encodeWorkspace(definition)
        currentProtobufBytes = bytes
        lastSavedBytes = bytes
        lastSavedPreferences = preferences
        lastSavedRevision = revision
    }

    public func markSaved(bytes: Data) {
        lastSavedBytes =
            (try? WorkspacePersistenceCodec.normalizeWorkspaceProtobuf(bytes))
            ?? bytes
        lastSavedPreferences = preferences
        lastSavedRevision = revision
    }

    public func persistenceSnapshot() throws -> WorkspacePersistenceSnapshot {
        let bytes = try currentProtobufBytes ?? WorkspacePersistenceCodec.encodeWorkspace(definition)
        return WorkspacePersistenceSnapshot(
            definition: definition,
            preferences: preferences,
            protobufData: bytes,
            revision: revision
        )
    }

    public func markSaved(_ snapshot: WorkspacePersistenceSnapshot) {
        guard snapshot.revision >= lastSavedRevision else { return }
        lastSavedBytes = snapshot.protobufData
        lastSavedPreferences = snapshot.preferences
        lastSavedRevision = snapshot.revision
    }

    private func noteDefinitionChanged() {
        currentProtobufBytes = try? WorkspacePersistenceCodec.encodeWorkspace(definition)
        revision &+= 1
    }
}
