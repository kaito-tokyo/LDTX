// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

enum ProgramLibraryError: LocalizedError {
    case duplicateProgramName(String)

    var errorDescription: String? {
        switch self {
        case let .duplicateProgramName(name):
            "A Program named \"\(name)\" already exists."
        }
    }
}

struct ProgramLibrary {
    private(set) var records: [SavedProgramDefinitionRecord] = []
    private(set) var selectedRecordName: String?

    private let service: any ProgramLibraryService

    init(service: any ProgramLibraryService) {
        self.service = service
    }

    var selectedRecord: SavedProgramDefinitionRecord? {
        guard let selectedRecordName else {
            return nil
        }
        return records.first { $0.name == selectedRecordName }
    }

    mutating func reload() throws {
        records = try service.loadProgramDefinitions()
        clearMissingSelection()
    }

    mutating func selectRecord(named name: String?) {
        selectedRecordName = name
    }

    mutating func replaceRecords(_ records: [SavedProgramDefinitionRecord], selectedName: String?) throws {
        self.records = records
        selectedRecordName = selectedName
        try service.saveProgramDefinitions(records)
        clearMissingSelection()
    }

    mutating func save(_ record: SavedProgramDefinitionRecord) throws {
        if let index = records.firstIndex(where: { $0.name == record.name }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try service.saveProgramDefinitions(records)
    }

    mutating func appendImported(_ record: SavedProgramDefinitionRecord) throws {
        records.append(record)
        try service.saveProgramDefinitions(records)
    }

    mutating func appendEmpty() throws -> SavedProgramDefinitionRecord {
        let namePrefix = records.isEmpty ? "New Program" : "New Program \(records.count + 1)"
        guard !records.contains(where: { $0.name == namePrefix }) else {
            throw ProgramLibraryError.duplicateProgramName(namePrefix)
        }
        let record = SavedProgramDefinitionRecord(
            name: namePrefix,
            canvasWidth: 1920,
            canvasHeight: 1080,
            frameRateNumerator: 60,
            frameRateDenominator: 1,
            composite: CompositeProgramDefinition()
        )
        try appendImported(record)
        selectedRecordName = record.name
        return record
    }

    mutating func ensureDefaultProgram() throws -> SavedProgramDefinitionRecord {
        if let selectedRecord {
            return selectedRecord
        }
        if let firstRecord = records.first {
            selectedRecordName = firstRecord.name
            return firstRecord
        }
        return try appendEmpty()
    }

    @discardableResult
    mutating func rename(oldName: String, to proposedName: String) throws -> SavedProgramDefinitionRecord? {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = records.firstIndex(where: { $0.name == oldName }) else {
            return nil
        }
        let newName = service.uniqueProgramDefinitionName(
            prefix: trimmedName,
            records: records,
            excluding: oldName
        )
        records[index].name = newName
        try service.saveProgramDefinitions(records)
        if selectedRecordName == oldName {
            selectedRecordName = newName
        }
        return records[index]
    }

    mutating func delete(named name: String) throws {
        records.removeAll { $0.name == name }
        try service.saveProgramDefinitions(records)
        if selectedRecordName == name {
            selectedRecordName = records.first?.name
        }
    }

    mutating func resetAfterRestoreFailure() {
        records = []
        selectedRecordName = nil
        service.resetProgramDefinitions()
    }

    private mutating func clearMissingSelection() {
        if let selectedRecordName,
           !records.contains(where: { $0.name == selectedRecordName }) {
            self.selectedRecordName = nil
        }
    }
}
