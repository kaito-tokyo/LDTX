// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgramRuntime
import XCTest

@MainActor
final class ProgramOutputSessionTests: XCTestCase {
  func testSessionKeepsInjectedDiagnosticIdentifier() {
    let id = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let session = ProgramOutputSession(
      id: id,
      activeProgramRuntime: ActiveProgramRuntime(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator()
      )
    )

    XCTAssertEqual(session.id, id)
  }
}
