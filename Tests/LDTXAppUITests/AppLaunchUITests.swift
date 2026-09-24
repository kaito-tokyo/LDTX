// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@MainActor
final class AppLaunchUITests: XCTestCase {
  func testLauncherOffersWorkspaceAndFileActions() async {
    let app = XCUIApplication()
    configureForUITesting(app)
    app.launch()

    await assertExists(app.staticTexts["LDTX"], timeout: 10)
    XCTAssertTrue(app.buttons["New Workspace"].exists)
    XCTAssertTrue(app.buttons["Open File…"].exists)
  }

  func testWorkspacePaneControlsChangeVisibleLayoutAndWindowCanClose() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("LDTXAppUITests-\(UUID().uuidString).ldtxworkspace")
    defer { try? FileManager.default.removeItem(at: workspaceURL) }

    let app = XCUIApplication()
    configureForUITesting(app)
    app.launchEnvironment["LDTX_UI_TEST_WORKSPACE_PATH"] = workspaceURL.path
    app.launch()

    let inspectorToggle = app.toolbars.buttons["Inspector"]
    await assertExists(inspectorToggle, timeout: 10)
    let inspector = app.descendants(matching: .any)["workspaceInspector"]
    await assertExists(inspector, timeout: 10)
    inspectorToggle.click()
    await assertDoesNotExist(inspector, timeout: 2)
    inspectorToggle.click()
    await assertExists(inspector, timeout: 2)

    app.typeKey("w", modifierFlags: .command)
    await assertDoesNotExist(app.toolbars.buttons["Inspector"], timeout: 10)
  }

  private func configureForUITesting(_ app: XCUIApplication) {
    app.launchArguments += ["-tokyo.kaito.ldtx.LDTX.isUITesting", "YES"]

    // macOS reports a Security framework runtime issue when XCUI queries accessibility.
    app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
  }

  private func assertExists(_ element: XCUIElement, timeout: TimeInterval) async {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true"),
      object: element
    )
    await fulfillment(of: [expectation], timeout: timeout)
  }

  private func assertDoesNotExist(_ element: XCUIElement, timeout: TimeInterval) async {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: element
    )
    await fulfillment(of: [expectation], timeout: timeout)
  }
}
