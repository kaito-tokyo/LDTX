// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgramRuntime
import LDTXWorkspace
import Testing
@testable import LDTXAppCore

@MainActor
@Suite("Version 4 Workspace runtime session")
struct WorkspaceV4RuntimeSessionUnitTestSuite {
  @Test("saves and opens a V4 package without a V3 session")
  func savesAndOpensV4Package() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Unite.ldtxworkspace")
    let capture = WorkspaceCaptureSessionCoordinator()
    let session = try makeSession(capture: capture)
    try session.store.addProgram(displayName: "Main")

    try session.save(to: packageURL)
    #expect(session.url == packageURL)
    #expect(!session.isDirty)
    session.close()

    let reopened = try makeSession(capture: capture)
    try reopened.open(at: packageURL)
    #expect(reopened.store.workspace.definition.definition.programs.map(\.displayName) == ["Main"])
    reopened.close()
  }

  private func makeSession(
    capture: WorkspaceCaptureSessionCoordinator
  ) throws -> WorkspaceV4RuntimeSession {
    WorkspaceV4RuntimeSession(
      persistence: try WorkspaceV4PersistenceCoordinator(
        store: WorkspaceV4Store(cleanNamed: "Unite")),
      captureSessionCoordinator: capture
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
