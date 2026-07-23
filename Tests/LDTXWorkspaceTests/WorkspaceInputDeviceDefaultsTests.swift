// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import Testing

struct WorkspaceInputDeviceDefaultsTests {
    @Test func defaultInputDeviceIsVideoSourceWithoutPhysicalDevice() {
        let inputDevice = WorkspaceInputDeviceDefaults.makeDefaultVideoInputDevice(
            existingInputDevices: []
        )

        #expect(inputDevice.name == "Input 1")
        #expect(inputDevice.kind == .video)
        #expect(inputDevice.physicalDeviceID == nil)
    }

    @Test func defaultInputDeviceNameUsesInputCountPlusOne() {
        let inputDevice = WorkspaceInputDeviceDefaults.makeDefaultVideoInputDevice(
            existingInputDevices: [
                WorkspaceInputDeviceRecord(name: "Input 1", kind: .video),
                WorkspaceInputDeviceRecord(name: "Custom Input", kind: .audio)
            ]
        )

        #expect(inputDevice.name == "Input 3")
    }

    @Test func defaultInputDeviceNameSkipsExistingCountBasedName() {
        let inputDevice = WorkspaceInputDeviceDefaults.makeDefaultVideoInputDevice(
            existingInputDevices: [
                WorkspaceInputDeviceRecord(name: "Input 1", kind: .video),
                WorkspaceInputDeviceRecord(name: "Input 3", kind: .audio)
            ]
        )

        #expect(inputDevice.name == "Input 4")
    }

    @Test func numberedResourceNameUsesNextWorkspaceNumberAndTrimsLabel() {
        let name = WorkspaceResourceNameValidator.nextNumberedName(
            label: "  Video Capture  ",
            inputDevices: [
                WorkspaceInputDeviceRecord(name: "1-Camera", kind: .video),
                WorkspaceInputDeviceRecord(name: "Unnumbered Legacy Input", kind: .audio)
            ],
            videoComponents: [WorkspaceVideoComponentRecord(name: "7-Overlay")],
            visions: []
        )

        #expect(name == "8-Video Capture")
    }
}
