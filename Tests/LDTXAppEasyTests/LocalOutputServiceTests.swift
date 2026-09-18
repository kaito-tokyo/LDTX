// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXApp

@Suite
struct LocalOutputServiceIntegrationTestSuite {
  @Test func writableBaseDirectoryProbeLeavesDirectoryUnchanged() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LDTXLocalOutputServiceIntegrationTestSuite-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = DefaultLocalOutputService(fileManager: .default)

    try service.validateWritableBaseDirectory(directory)

    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [])
  }

  @Test func missingBaseDirectoryReportsUnavailable() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LDTXMissingLocalOutputServiceIntegrationTestSuite-\(UUID().uuidString)", isDirectory: true)
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
