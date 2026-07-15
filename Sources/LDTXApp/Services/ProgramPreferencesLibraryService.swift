// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

protocol ProgramPreferencesLibraryService {
    func loadProgramPreferences() throws -> [SavedProgramPreferencesRecord]
    func saveProgramPreferences(_ records: [SavedProgramPreferencesRecord]) throws
    func resetProgramPreferences()
}

struct DefaultProgramPreferencesLibraryService: ProgramPreferencesLibraryService {
    private static let userDefaultsKey = "tokyo.kaito.ldtx.programPreferences.v2"
    private static let legacyUserDefaultsKey = "tokyo.kaito.ldtx.programPreferences.v1"

    private let userDefaults: UserDefaults
    private let legacyDecoder: JSONDecoder

    init(
        userDefaults: UserDefaults,
        decoder: JSONDecoder,
        encoder _: JSONEncoder
    ) {
        self.userDefaults = userDefaults
        legacyDecoder = decoder
    }

    func loadProgramPreferences() throws -> [SavedProgramPreferencesRecord] {
        guard let data = userDefaults.data(forKey: Self.userDefaultsKey) else {
            return try loadLegacyProgramPreferences()
        }
        return try ProgramPersistenceCodec.decodeProgramPreferences(from: data)
    }

    func saveProgramPreferences(_ records: [SavedProgramPreferencesRecord]) throws {
        let data = try ProgramPersistenceCodec.encodeProgramPreferences(records)
        userDefaults.set(data, forKey: Self.userDefaultsKey)
        userDefaults.removeObject(forKey: Self.legacyUserDefaultsKey)
    }

    func resetProgramPreferences() {
        userDefaults.removeObject(forKey: Self.userDefaultsKey)
        userDefaults.removeObject(forKey: Self.legacyUserDefaultsKey)
    }

    private func loadLegacyProgramPreferences() throws -> [SavedProgramPreferencesRecord] {
        guard let data = userDefaults.data(forKey: Self.legacyUserDefaultsKey) else {
            return []
        }
        let records = try legacyDecoder.decode([SavedProgramPreferencesRecord].self, from: data)
        try saveProgramPreferences(records)
        return records
    }
}

final class InMemoryProgramPreferencesLibraryService: ProgramPreferencesLibraryService {
    private var records: [SavedProgramPreferencesRecord]

    init(records: [SavedProgramPreferencesRecord] = []) {
        self.records = records
    }

    func loadProgramPreferences() throws -> [SavedProgramPreferencesRecord] {
        records
    }

    func saveProgramPreferences(_ records: [SavedProgramPreferencesRecord]) throws {
        self.records = records
    }

    func resetProgramPreferences() {
        records = []
    }
}
