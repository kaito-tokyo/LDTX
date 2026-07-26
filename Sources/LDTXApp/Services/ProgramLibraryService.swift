// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

protocol ProgramLibraryService {
    func loadProgramDefinitions() throws -> [SavedProgramDefinitionRecord]
    func saveProgramDefinitions(_ records: [SavedProgramDefinitionRecord]) throws
    func resetProgramDefinitions()
    func uniqueProgramDefinitionName(
        prefix: String,
        records: [SavedProgramDefinitionRecord],
        excluding excludedName: String?
    ) -> String
}

struct DefaultProgramLibraryService: ProgramLibraryService {
    private static let userDefaultsKey = "tokyo.kaito.ldtx.programDefinitions.v2"

    private let userDefaults: UserDefaults

    init(
        userDefaults: UserDefaults,
        decoder _: JSONDecoder,
        encoder _: JSONEncoder
    ) {
        self.userDefaults = userDefaults
    }

    func loadProgramDefinitions() throws -> [SavedProgramDefinitionRecord] {
        guard let data = userDefaults.data(forKey: Self.userDefaultsKey) else { return [] }
        return try ProgramPersistenceCodec.decodeProgramDefinitions(from: data)
    }

    func saveProgramDefinitions(_ records: [SavedProgramDefinitionRecord]) throws {
        let data = try ProgramPersistenceCodec.encodeProgramDefinitions(records)
        userDefaults.set(data, forKey: Self.userDefaultsKey)
    }

    func resetProgramDefinitions() {
        userDefaults.removeObject(forKey: Self.userDefaultsKey)
    }

    func uniqueProgramDefinitionName(
        prefix: String,
        records: [SavedProgramDefinitionRecord],
        excluding excludedName: String? = nil
    ) -> String {
        if !records.contains(where: { $0.name == prefix && $0.name != excludedName }) {
            return prefix
        }
        var index = records.count + 1
        var candidate = "\(prefix) \(index)"
        while records.contains(where: { $0.name == candidate && $0.name != excludedName }) {
            index += 1
            candidate = "\(prefix) \(index)"
        }
        return candidate
    }
}

final class InMemoryProgramLibraryService: ProgramLibraryService {
    private var records: [SavedProgramDefinitionRecord]

    init(records: [SavedProgramDefinitionRecord] = []) {
        self.records = records
    }

    func loadProgramDefinitions() throws -> [SavedProgramDefinitionRecord] {
        records
    }

    func saveProgramDefinitions(_ records: [SavedProgramDefinitionRecord]) throws {
        self.records = records
    }

    func resetProgramDefinitions() {
        records = []
    }

    func uniqueProgramDefinitionName(
        prefix: String,
        records: [SavedProgramDefinitionRecord],
        excluding excludedName: String? = nil
    ) -> String {
        if !records.contains(where: { $0.name == prefix && $0.name != excludedName }) {
            return prefix
        }
        var index = records.count + 1
        var candidate = "\(prefix) \(index)"
        while records.contains(where: { $0.name == candidate && $0.name != excludedName }) {
            index += 1
            candidate = "\(prefix) \(index)"
        }
        return candidate
    }
}
