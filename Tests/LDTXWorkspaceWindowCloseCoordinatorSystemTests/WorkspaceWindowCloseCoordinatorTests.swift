// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import Testing

@Suite
@MainActor
struct WorkspaceWindowCloseCoordinatorUnitTestSuite {
  @Test func testCloseModeSkipsPromptAndSaveButStillStopsOnce() {
    let gate = WorkspaceV4WindowCloseCoordinator(discardsUnsavedChangesOnClose: true)
    _ = NSApplication.shared
    let window = NSWindow()
    var confirmations = 0
    var saves = 0
    var stops = 0
    gate.chooseCloseAction = { _ in
      confirmations += 1
      return .abort
    }
    gate.beginInstalling(
      window: window, hasUnsavedChanges: true,
      saveBeforeClose: {
        saves += 1
        return true
      },
      onClose: { _ in stops += 1 }, onBecomeKey: {})
    #expect(gate.confirmClose())
    #expect(!gate.windowShouldClose(window))
    #expect(!gate.windowShouldClose(window))
    #expect(confirmations == 0)
    #expect(saves == 0)
    #expect(stops == 1)
  }

  @Test func failedSavePreventsCloseAndShutdown() {
    let gate = WorkspaceV4WindowCloseCoordinator()
    _ = NSApplication.shared
    let window = NSWindow()
    var stops = 0
    gate.chooseCloseAction = { _ in .alertFirstButtonReturn }
    gate.beginInstalling(
      window: window, hasUnsavedChanges: true, saveBeforeClose: { false },
      onClose: { _ in stops += 1 }, onBecomeKey: {})
    #expect(!gate.windowShouldClose(window))
    #expect(stops == 0)
  }

  @Test func discardConfirmationDoesNotEraseDirtyStateBeforeQuitCommits() {
    let gate = WorkspaceV4WindowCloseCoordinator()
    _ = NSApplication.shared
    let window = NSWindow()
    var confirmations = 0
    gate.chooseCloseAction = { _ in
      confirmations += 1
      return .alertSecondButtonReturn
    }
    gate.beginInstalling(
      window: window, hasUnsavedChanges: true, saveBeforeClose: { true }, onClose: { _ in },
      onBecomeKey: {})
    #expect(gate.confirmClose())
    #expect(gate.confirmClose())
    #expect(confirmations == 2)
  }

  @Test func repeatedCloseRequestsStartShutdownOnlyOnce() {
    let gate = WorkspaceV4WindowCloseCoordinator()
    _ = NSApplication.shared
    let window = NSWindow()
    var stops = 0
    gate.beginInstalling(
      window: window, hasUnsavedChanges: false, saveBeforeClose: { true },
      onClose: { _ in stops += 1 }, onBecomeKey: {})
    #expect(!gate.windowShouldClose(window))
    #expect(!gate.windowShouldClose(window))
    #expect(stops == 1)
  }
}
