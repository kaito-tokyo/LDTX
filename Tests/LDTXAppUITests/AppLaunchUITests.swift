// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import XCTest

final class AppLaunchUITests: XCTestCase {
  func testLauncherOffersWorkspaceAndFileActions() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.staticTexts["LDTX"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["New Workspace"].exists)
    XCTAssertTrue(app.buttons["Open File…"].exists)
  }
}
