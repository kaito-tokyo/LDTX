// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import XCTest

final class LDTXUITests: XCTestCase {
    func testAddingInputCameraDeviceShowsInputMapping() throws {
        continueAfterFailure = false

        let app = launchApp()
        app.launch()
        selectNewProgram(in: app)

        XCTAssertTrue(
            app.buttons["addProgramComponentButton"].waitForExistence(timeout: 5),
            "New Program should start with no input mappings."
        )
        XCTAssertNil(
            firstExistingMappingPickerIfPresent(in: app, timeout: 1),
            "New Program should start with no input mappings."
        )

        app.buttons["addProgramComponentButton"].click()

        let componentPicker = try firstExistingElement(
            [
                app.popUpButtons["programComponentPicker"].firstMatch,
                app.buttons["programComponentPicker"].firstMatch
            ],
            timeout: 5,
            description: "component picker"
        )
        componentPicker.click()
        app.menuItems["Input Camera Device"].firstMatch.click()

        _ = try firstExistingMappingPicker(in: app, timeout: 5)
    }

    func testCommandSSavesNewProgramAsSavedProgramDefinition() throws {
        continueAfterFailure = false

        let app = launchApp()
        app.launch()
        selectNewProgram(in: app)

        XCTAssertTrue(
            app.buttons["addProgramComponentButton"].waitForExistence(timeout: 5),
            "New Program should be open before saving."
        )

        app.buttons["addProgramComponentButton"].click()
        app.typeKey("s", modifierFlags: .command)

        XCTAssertTrue(
            app.textFields["savedProgramDefinitionNameField.New Program 1"].waitForExistence(timeout: 1),
            "Saving New Program should create a persisted Program row."
        )
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-tokyo.kaito.ldtx.LDTX.isUITesting",
            "YES",
            "-ApplePersistenceIgnoreState",
            "YES"
        ]
        return app
    }

    private func selectNewProgram(in app: XCUIApplication) {
        app.staticTexts["scratchPadProgramDefinitionRow"].firstMatch.click()
    }

    private func firstExistingMappingPicker(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> XCUIElement {
        if let element = firstExistingMappingPickerIfPresent(in: app, timeout: timeout) {
            return element
        }

        XCTFail("Could not find input camera device mapping picker.")
        throw UIElementLookupError.notFound("input camera device mapping picker")
    }

    private func firstExistingMappingPickerIfPresent(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let exactID = "inputCameraDeviceMappingPicker.inputCameraDevice 1"
        let exactCandidates = [
            app.popUpButtons[exactID].firstMatch,
            app.buttons[exactID].firstMatch
        ]
        if let exactElement = firstExistingElementIfPresent(
            exactCandidates,
            timeout: timeout
        ) {
            return exactElement
        }

        let prefixPredicate = NSPredicate(
            format: "identifier BEGINSWITH %@",
            "inputCameraDeviceMappingPicker."
        )
        let fallbackCandidates = [
            app.popUpButtons.matching(prefixPredicate).firstMatch,
            app.buttons.matching(prefixPredicate).firstMatch
        ]
        return firstExistingElementIfPresent(
            fallbackCandidates,
            timeout: 1
        )
    }

    private func firstExistingElement(
        _ elements: [XCUIElement],
        timeout: TimeInterval,
        description: String
    ) throws -> XCUIElement {
        if let element = firstExistingElementIfPresent(elements, timeout: timeout) {
            return element
        }

        XCTFail("Could not find \(description).")
        throw UIElementLookupError.notFound(description)
    }

    private func firstExistingElementIfPresent(
        _ elements: [XCUIElement],
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = elements.first(where: \.exists) {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return nil
    }
}

private enum UIElementLookupError: Error {
    case notFound(String)
}
