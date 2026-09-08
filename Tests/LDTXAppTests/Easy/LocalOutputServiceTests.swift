// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXAppCore

@Suite("LDTXAppCoreEasyTests", .tags(.easy))
struct LocalOutputServiceTests {
  @Test func writableBaseDirectoryProbeLeavesDirectoryUnchanged() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LDTXLocalOutputServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = DefaultLocalOutputService(fileManager: .default)

    try service.validateWritableBaseDirectory(directory)

    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [])
  }

  @Test func missingBaseDirectoryReportsUnavailable() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LDTXMissingLocalOutputServiceTests-\(UUID().uuidString)", isDirectory: true)
    let service = DefaultLocalOutputService(fileManager: .default)

    do {
      try service.validateWritableBaseDirectory(directory)
      Issue.record("Expected unavailable output directory error")
    } catch let error as LocalOutputServiceError {
      guard case .outputDirectoryUnavailable(let path) = error else {
        Issue.record("Unexpected output service error: \(error)")
        return
      }
      #expect(path == directory.path)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
