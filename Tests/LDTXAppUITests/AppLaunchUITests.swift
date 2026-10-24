// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXRecordBundleFormat
import XCTest

@MainActor
final class AppLaunchUITests: XCTestCase {
  func testLUB1037_NewWorkspaceShowsPreview() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-tokyo.kaito.ldtx.LDTX.isUITesting", "YES",
    ]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.menuBars.menuBarItems["File"].waitForExistence(timeout: 15))
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    app.menuBars.menuBarItems["File"].click()
    app.menuItems["New"].hover()
    app.menuItems["New Document"].click()
    XCTAssertTrue(app.images["canvasPairPreview"].waitForExistence(timeout: 15))
    app.menuBars.menuBarItems["File"].click()
    app.menuItems["New"].hover()
    app.menuItems["New Document"].click()
    let previews = app.images.matching(identifier: "canvasPairPreview")
    XCTAssertTrue(previews.element(boundBy: 1).waitForExistence(timeout: 15))
    XCTAssertEqual(previews.count, 2)
  }

  func testLUB1037_VisionProgrammerOpensFromEveryScene() async throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-tokyo.kaito.ldtx.LDTX.isUITesting", "YES",
    ]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.menuBars.menuBarItems["File"].waitForExistence(timeout: 15))
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

    // Explicitly create and focus the Workspace document scene.
    app.menuBars.menuBarItems["File"].click()
    app.menuItems["New"].hover()
    app.menuItems["New Document"].click()
    XCTAssertTrue(app.images["canvasPairPreview"].waitForExistence(timeout: 15))
    try openVisionProgrammer(app, from: "Workspace")

    // The command must also remain usable while its own window is active.
    try openVisionProgrammer(app, from: "Vision Programmer")
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(app.windows["Scene Detector"].waitForNonExistence(timeout: 5))

    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["com_apple_SwiftUI_Settings_window"]
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    try openVisionProgrammer(app, from: "Settings")
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(app.windows["Scene Detector"].waitForNonExistence(timeout: 5))

    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("ldtxrecord")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    try RecordingPackageInfo.data(
      identifier: "scene-command-ui-test", mainMediaFile: "main.mp4", audioTracks: [],
      formatVersion: 2
    ).write(to: url.appendingPathComponent(RecordingPackageInfo.fileName))
    try await makeMenuSmokeMedia(at: url.appendingPathComponent("main.mp4"))
    try "<MPD><Period/></MPD>".write(
      to: url.appendingPathComponent("manifest.mpd"), atomically: true, encoding: .utf8)
    app.menuBars.menuBarItems["File"].click()
    app.menuItems["Open…"].click()
    let open = app.windows.buttons["Open"].firstMatch
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    app.typeKey("g", modifierFlags: [.command, .shift])
    app.typeText(url.path)
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    let package = app.windows.textFields.matching(
      NSPredicate(format: "value == %@", url.lastPathComponent)
    ).firstMatch
    XCTAssertTrue(package.waitForExistence(timeout: 10))
    XCTAssertTrue(open.isEnabled)
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    XCTAssertTrue(open.waitForNonExistence(timeout: 10))
    let recording = app.windows[url.lastPathComponent]
    XCTAssertTrue(recording.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Loading Recording…"].waitForNonExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Recording Could Not Be Opened"].exists)
    recording.click()
    try openVisionProgrammer(app, from: "Record Player")
  }

  private func openVisionProgrammer(_ app: XCUIApplication, from scene: String) throws {
    app.menuBars.menuBarItems["LDTX"].click()
    let commands = app.menuItems.matching(identifier: "Vision Programmer…")
    XCTAssertEqual(commands.count, 1, "Exactly one command should be visible from \(scene)")
    let command = commands.firstMatch
    XCTAssertTrue(command.isEnabled, "The command must be enabled from \(scene)")
    command.click()
    XCTAssertTrue(
      app.windows["Scene Detector"].waitForExistence(timeout: 5),
      "Vision Programmer should open from \(scene)")
  }

  func testLUB1037_RecordingOpensThroughDocumentGroup() throws {
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
    // Let Go to Folder select the exact package. Clicking its row can make XCUI
    // try to scroll an off-screen Open panel on CI, where no hit point exists.
    app.typeText(url.path)
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    let package = app.windows.textFields.matching(
      NSPredicate(format: "value == %@", url.lastPathComponent)
    ).firstMatch
    guard package.waitForExistence(timeout: 10) else {
      recordOpenFailure(app, message: "The recording package did not appear in the Open panel.")
      return
    }
    guard
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
        ],
        timeout: 10
      ) == .completed
    else {
      recordOpenFailure(app, message: "The Open button did not become enabled for the recording.")
      return
    }
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    guard open.waitForNonExistence(timeout: 10) else {
      recordOpenFailure(app, message: "The Open panel did not close after opening the recording.")
      return
    }
    // Valid package metadata reaches the player; deliberately invalid media uses its SwiftUI alert.
    guard app.staticTexts["Recording Could Not Be Opened"].waitForExistence(timeout: 10) else {
      recordOpenFailure(app, message: "The invalid-media alert did not appear.")
      return
    }
    let ok = app.windows.buttons["OK"].firstMatch
    guard ok.waitForExistence(timeout: 5) else {
      recordOpenFailure(app, message: "The invalid-media alert's OK button did not appear.")
      return
    }
    ok.click()
    XCTAssertTrue(app.staticTexts["Recording Could Not Be Opened"].waitForNonExistence(timeout: 5))
  }

  private func recordOpenFailure(
    _ app: XCUIApplication, message: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "Recording open accessibility hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.lifetime = .keepAlways
    add(screenshot)
    XCTFail(message, file: file, line: line)
  }

  func testLUB1037_ApplicationLaunchesWithFileActions() {
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
