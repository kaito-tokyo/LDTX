// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

enum ProgramLibraryError: LocalizedError {
  case duplicateProgramName(String)
  case invalidProgramName

  var errorDescription: String? {
    switch self {
    case .duplicateProgramName(let name):
      "A Program named \"\(name)\" already exists."
    case .invalidProgramName:
      "Enter a Program name."
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

  mutating func replaceRecords(_ records: [SavedProgramDefinitionRecord], selectedName: String?)
    throws
  {
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
    return try appendEmpty(named: namePrefix)
  }

  mutating func appendEmpty(named proposedName: String) throws -> SavedProgramDefinitionRecord {
    let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw ProgramLibraryError.invalidProgramName
    }
    guard !records.contains(where: { $0.name == name }) else {
      throw ProgramLibraryError.duplicateProgramName(name)
    }
    let record = SavedProgramDefinitionRecord(
      name: name,
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
  mutating func rename(oldName: String, to proposedName: String) throws
    -> SavedProgramDefinitionRecord?
  {
    let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty,
      let index = records.firstIndex(where: { $0.name == oldName })
    else {
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

  /// Moves a Program within the scene-selection order without changing its
  /// identity or the selected Program.
  @discardableResult
  mutating func move(named name: String, by offset: Int) throws -> Bool {
    guard let index = records.firstIndex(where: { $0.name == name }) else {
      return false
    }
    let destination = index + offset
    guard records.indices.contains(destination) else {
      return false
    }
    records.swapAt(index, destination)
    try service.saveProgramDefinitions(records)
    return true
  }

  mutating func resetAfterRestoreFailure() {
    records = []
    selectedRecordName = nil
    service.resetProgramDefinitions()
  }

  private mutating func clearMissingSelection() {
    if let selectedRecordName,
      !records.contains(where: { $0.name == selectedRecordName })
    {
      self.selectedRecordName = nil
    }
  }
}
