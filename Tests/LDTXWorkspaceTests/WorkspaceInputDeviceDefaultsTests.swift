// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import XCTest

final class WorkspaceInputDeviceDefaultsTests: XCTestCase {
    func testDefaultInputDeviceIsVideoSourceWithoutPhysicalDevice() {
        let inputDevice = WorkspaceInputDeviceDefaults.makeDefaultVideoInputDevice(
            existingInputDevices: []
        )

        XCTAssertEqual(inputDevice.name, "Input 1")
        XCTAssertEqual(inputDevice.kind, .video)
        XCTAssertNil(inputDevice.physicalDeviceID)
    }

    func testDefaultInputDeviceNameUsesInputCountPlusOne() {
        let inputDevice = WorkspaceInputDeviceDefaults.makeDefaultVideoInputDevice(
            existingInputDevices: [
                WorkspaceInputDeviceRecord(name: "Input 1", kind: .video),
                WorkspaceInputDeviceRecord(name: "Custom Input", kind: .audio)
            ]
        )

        XCTAssertEqual(inputDevice.name, "Input 3")
    }

    func testDefaultInputDeviceNameSkipsExistingCountBasedName() {
        let inputDevice = WorkspaceInputDeviceDefaults.makeDefaultVideoInputDevice(
            existingInputDevices: [
                WorkspaceInputDeviceRecord(name: "Input 1", kind: .video),
                WorkspaceInputDeviceRecord(name: "Input 3", kind: .audio)
            ]
        )

        XCTAssertEqual(inputDevice.name, "Input 4")
    }
}
