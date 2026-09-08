// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import LDTXAppCore

final class LocalOutputServiceTests: XCTestCase {
  func testWritableBaseDirectoryProbeLeavesDirectoryUnchanged() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LDTXLocalOutputServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = DefaultLocalOutputService(fileManager: .default)

    try service.validateWritableBaseDirectory(directory)

    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
  }

  func testMissingBaseDirectoryReportsUnavailable() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LDTXMissingLocalOutputServiceTests-\(UUID().uuidString)", isDirectory: true)
    let service = DefaultLocalOutputService(fileManager: .default)

    XCTAssertThrowsError(try service.validateWritableBaseDirectory(directory)) { error in
      guard let outputError = error as? LocalOutputServiceError,
        case .outputDirectoryUnavailable(let path) = outputError
      else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(path, directory.path)
    }
  }
}
