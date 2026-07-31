// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import Testing

@testable import LDTXAppCore

struct ProgramLibraryTests {
  @Test func moveChangesOnlyTheProgramOrder() throws {
    var library = ProgramLibrary(service: InMemoryProgramLibraryService())
    _ = try library.appendEmpty(named: "One")
    _ = try library.appendEmpty(named: "Two")
    _ = try library.appendEmpty(named: "Three")

    #expect(try library.move(named: "Two", by: 1))

    #expect(library.records.map(\.name) == ["One", "Three", "Two"])
    #expect(library.selectedRecordName == "Three")
  }

  @Test func moveAtBoundaryDoesNotPersistAnInvalidOrder() throws {
    var library = ProgramLibrary(service: InMemoryProgramLibraryService())
    _ = try library.appendEmpty(named: "One")
    _ = try library.appendEmpty(named: "Two")

    #expect(try !library.move(named: "One", by: -1))
    #expect(try !library.move(named: "Two", by: 1))
    #expect(library.records.map(\.name) == ["One", "Two"])
  }
}
