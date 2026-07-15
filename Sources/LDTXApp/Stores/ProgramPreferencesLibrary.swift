// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

struct ProgramPreferencesLibrary {
    private(set) var records: [SavedProgramPreferencesRecord] = []

    private let service: any ProgramPreferencesLibraryService

    init(service: any ProgramPreferencesLibraryService) {
        self.service = service
    }

    func preferences(named name: String) -> ProgramPreferences? {
        records.first { $0.name == name }?.preferences
    }

    mutating func reload() throws {
        records = try service.loadProgramPreferences()
    }

    mutating func replaceRecords(_ records: [SavedProgramPreferencesRecord]) throws {
        self.records = records
        try service.saveProgramPreferences(records)
    }

    mutating func save(_ preferences: ProgramPreferences, named name: String) throws {
        let record = SavedProgramPreferencesRecord(name: name, preferences: preferences)
        if let index = records.firstIndex(where: { $0.name == name }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try service.saveProgramPreferences(records)
    }

    mutating func rename(oldName: String, to newName: String) throws {
        guard let index = records.firstIndex(where: { $0.name == oldName }) else {
            return
        }
        records[index].name = newName
        try service.saveProgramPreferences(records)
    }

    mutating func delete(named name: String) throws {
        records.removeAll { $0.name == name }
        try service.saveProgramPreferences(records)
    }

    mutating func resetAfterRestoreFailure() {
        records = []
        service.resetProgramPreferences()
    }
}
