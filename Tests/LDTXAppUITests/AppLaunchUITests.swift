// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@MainActor
final class AppLaunchUITests: XCTestCase {
  func testLauncherOffersWorkspaceAndFileActions() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.staticTexts["LDTX"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["New Workspace"].exists)
    XCTAssertTrue(app.buttons["Open File…"].exists)
  }

  func testWorkspacePaneControlsChangeVisibleLayoutAndWindowCanClose() throws {
    let workspaceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("LDTXAppUITests-\(UUID().uuidString).ldtxworkspace")
    defer { try? FileManager.default.removeItem(at: workspaceURL) }

    let app = XCUIApplication()
    app.launchArguments += ["-tokyo.kaito.ldtx.LDTX.isUITesting", "YES"]
    app.launchEnvironment["LDTX_UI_TEST_WORKSPACE_PATH"] = workspaceURL.path
    app.launch()

    let inspectorToggle = app.toolbars.buttons["Inspector"]
    XCTAssertTrue(inspectorToggle.waitForExistence(timeout: 10))
    let inspector = app.descendants(matching: .any)["workspaceInspector"]
    XCTAssertTrue(inspector.waitForExistence(timeout: 10))
    inspectorToggle.click()
    XCTAssertTrue(inspector.waitForNonExistence(timeout: 2))
    inspectorToggle.click()
    XCTAssertTrue(inspector.waitForExistence(timeout: 2))

    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(app.toolbars.buttons["Inspector"].waitForNonExistence(timeout: 10))
  }
}
