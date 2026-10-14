// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXRecordBundleFormat
import XCTest

@MainActor
final class AppLaunchUITests: XCTestCase {
  func testRecordingOpensThroughDocumentGroup() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("ldtxrecord")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    try RecordingPackageInfo.data(
      identifier: "documentgroup-ui-test", mainMediaFile: "main.mp4", audioTracks: [],
      formatVersion: 2
    ).write(to: url.appendingPathComponent(RecordingPackageInfo.fileName))
    try Data().write(to: url.appendingPathComponent("main.mp4"))
    try Data().write(to: url.appendingPathComponent("manifest.mpd"))

    let app = XCUIApplication()
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-tokyo.kaito.ldtx.LDTX.isUITesting", "YES",
    ]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.menuBars.menuBarItems["File"].waitForExistence(timeout: 15))
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    app.menuBars.menuBarItems["File"].click()
    app.menuItems["Open…"].click()
    // NSOpenPanel may be exposed as a window or sheet rather than a dialog.
    let open = app.windows.buttons["Open"].firstMatch
    guard open.waitForExistence(timeout: 10) else {
      XCTFail("The Open panel did not appear.")
      return
    }
    app.typeKey("g", modifierFlags: [.command, .shift])
    app.typeText(url.path)
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    open.click()
    // Valid package metadata reaches the player; deliberately invalid media uses its SwiftUI alert.
    XCTAssertTrue(app.staticTexts["Recording Could Not Be Opened"].waitForExistence(timeout: 10))
    app.windows.buttons["OK"].firstMatch.click()
    XCTAssertFalse(app.staticTexts["Recording Could Not Be Opened"].waitForExistence(timeout: 2))
  }

  func testApplicationLaunchesWithFileActions() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-tokyo.kaito.ldtx.LDTX.isUITesting", "YES",
    ]
    app.launch()
    defer { app.terminate() }
    let file = app.menuBars.menuBarItems["File"]
    XCTAssertTrue(file.waitForExistence(timeout: 15))
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    file.click()
    let new = app.menuItems["New"]
    XCTAssertTrue(new.waitForExistence(timeout: 5))
    new.hover()
    XCTAssertTrue(app.menuItems["New Document"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.menuItems["New Document"].isEnabled)
    XCTAssertTrue(app.menuItems["Open…"].exists)
    XCTAssertTrue(app.menuItems["Open…"].isEnabled)
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    app.menuBars.menuBarItems["LDTX"].click()
    let programmer = app.menuItems["Vision Programmer…"]
    XCTAssertTrue(programmer.isEnabled)
    programmer.click()
    let window = app.windows["Scene Detector"]
    XCTAssertTrue(window.waitForExistence(timeout: 5))
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(
      app.windows["Audio"].waitForExistence(timeout: 5)
        || app.windows["Account"].exists || app.windows["Output"].exists)
  }

}
