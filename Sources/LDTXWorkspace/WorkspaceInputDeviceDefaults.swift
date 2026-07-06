// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

public enum WorkspaceInputDeviceDefaults {
    public static func makeDefaultVideoInputDevice(
        existingInputDevices: [WorkspaceInputDeviceRecord]
    ) -> WorkspaceInputDeviceRecord {
        WorkspaceInputDeviceRecord(
            name: nextInputDeviceName(existingInputDevices: existingInputDevices),
            kind: .video
        )
    }

    private static func nextInputDeviceName(
        existingInputDevices: [WorkspaceInputDeviceRecord]
    ) -> String {
        let existingNames = Set(existingInputDevices.map(\.name))
        var candidateNumber = existingInputDevices.count + 1
        while existingNames.contains("Input \(candidateNumber)") {
            candidateNumber += 1
        }
        return "Input \(candidateNumber)"
    }
}
