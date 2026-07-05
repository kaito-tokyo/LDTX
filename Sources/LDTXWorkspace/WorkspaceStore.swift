// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

@MainActor
@Observable
public final class WorkspaceStore {
    public private(set) var definition: WorkspaceDefinition

    @ObservationIgnored
    private var lastSavedBytes: Data

    public var isDirty: Bool {
        guard let currentBytes = try? WorkspacePersistenceCodec.encodeWorkspace(definition) else {
            return true
        }
        return currentBytes != lastSavedBytes
    }

    public init(definition: WorkspaceDefinition, lastSavedBytes: Data) {
        self.definition = definition
        self.lastSavedBytes = lastSavedBytes
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

    public func replaceDefinition(_ definition: WorkspaceDefinition) {
        self.definition = definition
    }

    public func markSaved() throws {
        lastSavedBytes = try WorkspacePersistenceCodec.encodeWorkspace(definition)
    }

    public func markSaved(bytes: Data) {
        lastSavedBytes = bytes
    }
}
