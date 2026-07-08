// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

public enum LDTXAutomationMethod {
    public static let appRegister = "ldtx.app.register"
    public static let appTerminate = "ldtx.app.terminate"
    public static let programGet = "ldtx.program.get"
    public static let programSelect = "ldtx.program.select"
    public static let selectedProgramName = "ldtx.program.selectedName"
    public static let inputDevicesGet = "ldtx.workspace.inputDevices.get"
    public static let inputDeviceSelect = "ldtx.workspace.inputDevice.select"
    public static let recordStart = "ldtx.record.start"
    public static let recordStop = "ldtx.record.stop"
    public static let recordSplit = "ldtx.record.split"
    public static let outputSettingsGet = "ldtx.outputSettings.get"
    public static let outputSettingsSet = "ldtx.outputSettings.set"
}

public enum LDTXAutomationService {
    public static let machServiceName = "tokyo.kaito.ldtx.LDTX.BrokerService"
    public static let launchAgentPlistName = "tokyo.kaito.ldtx.LDTX.BrokerService.plist"
}
