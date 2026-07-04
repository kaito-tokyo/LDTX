// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

struct ProgramArgumentsLibrary {
    private(set) var records: [SavedProgramArgumentsRecord] = []

    private let service: any ProgramArgumentsLibraryService

    init(service: any ProgramArgumentsLibraryService) {
        self.service = service
    }

    func arguments(named name: String) -> ProgramArguments? {
        records.first { $0.name == name }?.arguments
    }

    mutating func reload() throws {
        records = try service.loadProgramArguments()
    }

    mutating func save(_ arguments: ProgramArguments, named name: String) throws {
        let record = SavedProgramArgumentsRecord(name: name, arguments: arguments)
        if let index = records.firstIndex(where: { $0.name == name }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try service.saveProgramArguments(records)
    }

    mutating func rename(oldName: String, to newName: String) throws {
        guard let index = records.firstIndex(where: { $0.name == oldName }) else {
            return
        }
        records[index].name = newName
        try service.saveProgramArguments(records)
    }

    mutating func delete(named name: String) throws {
        records.removeAll { $0.name == name }
        try service.saveProgramArguments(records)
    }

    mutating func resetAfterRestoreFailure() {
        records = []
        service.resetProgramArguments()
    }
}
