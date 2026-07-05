// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXYouTube

enum MainSidebarItem: Equatable {
    case program
    case inputDevice
}

struct MainWindowState: Equatable {
    var selectedSidebarItem: MainSidebarItem
    var selectedSavedProgramDefinitionName: String?
    var selectedWorkspaceInputDeviceID: String?
    var selectedBroadcastSourceMode: BroadcastSourceMode
    var selectedResolution: YouTubeLiveStreamResolution
    var selectedFrameRate: YouTubeLiveStreamFrameRate
    var selectedPrivacyStatus: YouTubeLiveBroadcastPrivacyStatus
    var selectedLatencyPreference: YouTubeLiveBroadcastLatencyPreference
    var selectedExistingBroadcastID: String?
    var selectedCaptureOutputMode: CaptureOutputMode
}

extension MainWindowState {
    static var initialValue: MainWindowState {
        defaultValue
    }

    static var defaultValue: MainWindowState {
        MainWindowState(
            selectedSidebarItem: .program,
            selectedSavedProgramDefinitionName: nil,
            selectedWorkspaceInputDeviceID: nil,
            selectedBroadcastSourceMode: .createNew,
            selectedResolution: .p1080,
            selectedFrameRate: .fps60,
            selectedPrivacyStatus: .private,
            selectedLatencyPreference: .low,
            selectedExistingBroadcastID: nil,
            selectedCaptureOutputMode: .youtube
        )
    }
}
