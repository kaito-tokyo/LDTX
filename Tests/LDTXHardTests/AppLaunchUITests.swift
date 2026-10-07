// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import XCTest

@MainActor
final class AppLaunchUITests: XCTestCase {
  func testApplicationLaunchesWithFileActions() {
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    defer { app.terminate() }

    let file = app.menuBars.menuBarItems["File"]
    XCTAssertTrue(file.waitForExistence(timeout: 15))
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    file.click()
    XCTAssertTrue(app.menuItems["New Workspace"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.menuItems["New Workspace"].isEnabled)
    XCTAssertTrue(app.menuItems["Open File…"].exists)
    XCTAssertTrue(app.menuItems["Open File…"].isEnabled)
  }
}
