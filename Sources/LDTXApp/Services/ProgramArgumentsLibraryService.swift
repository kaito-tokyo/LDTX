// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

protocol ProgramArgumentsLibraryService {
    func loadProgramArguments() throws -> [SavedProgramArgumentsRecord]
    func saveProgramArguments(_ records: [SavedProgramArgumentsRecord]) throws
    func resetProgramArguments()
}

struct DefaultProgramArgumentsLibraryService: ProgramArgumentsLibraryService {
    private static let userDefaultsKey = "tokyo.kaito.ldtx.programArguments.v2"
    private static let legacyUserDefaultsKey = "tokyo.kaito.ldtx.programArguments.v1"

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

    func loadProgramArguments() throws -> [SavedProgramArgumentsRecord] {
        guard let data = userDefaults.data(forKey: Self.userDefaultsKey) else {
            return try loadLegacyProgramArguments()
        }
        return try ProgramPersistenceCodec.decodeProgramArguments(from: data)
    }

    func saveProgramArguments(_ records: [SavedProgramArgumentsRecord]) throws {
        let data = try ProgramPersistenceCodec.encodeProgramArguments(records)
        userDefaults.set(data, forKey: Self.userDefaultsKey)
        userDefaults.removeObject(forKey: Self.legacyUserDefaultsKey)
    }

    func resetProgramArguments() {
        userDefaults.removeObject(forKey: Self.userDefaultsKey)
        userDefaults.removeObject(forKey: Self.legacyUserDefaultsKey)
    }

    private func loadLegacyProgramArguments() throws -> [SavedProgramArgumentsRecord] {
        guard let data = userDefaults.data(forKey: Self.legacyUserDefaultsKey) else {
            return []
        }
        let records = try legacyDecoder.decode([SavedProgramArgumentsRecord].self, from: data)
        try saveProgramArguments(records)
        return records
    }
}
