// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

@MainActor
@Observable
public final class WorkspaceStore {
    public private(set) var definition: WorkspaceDefinition
    public private(set) var preferences: WorkspacePreferences

    @ObservationIgnored
    private var lastSavedBytes: Data

    public var isDirty: Bool {
        guard let currentBytes = try? WorkspacePersistenceCodec.encodeWorkspace(definition) else {
            return true
        }
        return currentBytes != lastSavedBytes
    }

    public init(
        definition: WorkspaceDefinition,
        preferences: WorkspacePreferences = WorkspacePreferences(),
        lastSavedBytes: Data
    ) {
        self.definition = definition
        self.preferences = preferences
        self.lastSavedBytes = lastSavedBytes
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
    }

    public func editPreferences(_ mutation: (inout WorkspacePreferences) -> Void) {
        mutation(&preferences)
    }

    public func replacePreferences(_ preferences: WorkspacePreferences) {
        self.preferences = preferences
    }

    public func replaceDefinition(_ definition: WorkspaceDefinition) {
        self.definition = definition
    }

    /// Replaces the persisted Workspace state as one consistent pair.
    ///
    /// Operations such as a Workspace-wide rename rewrite references in both
    /// the definition and preferences. Publishing either half independently
    /// would expose an inconsistent state to observers.
    public func replace(with snapshot: WorkspaceSnapshot) {
        definition = snapshot.definition
        preferences = snapshot.preferences
    }

    public func markSaved() throws {
        lastSavedBytes = try WorkspacePersistenceCodec.encodeWorkspace(definition)
    }

    public func markSaved(bytes: Data) {
        lastSavedBytes = bytes
    }
}
