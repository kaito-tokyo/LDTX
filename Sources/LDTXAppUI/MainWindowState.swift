// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXYouTube

public struct MainWindowState: Equatable {
    public var selectedSidebarItem: MainSidebarItem
    public var selectedSavedProgramDefinitionName: String?
    public var selectedBroadcastSourceMode: BroadcastSourceMode
    public var selectedResolution: YouTubeLiveStreamResolution
    public var selectedFrameRate: YouTubeLiveStreamFrameRate
    public var selectedPrivacyStatus: YouTubeLiveBroadcastPrivacyStatus
    public var selectedLatencyPreference: YouTubeLiveBroadcastLatencyPreference
    public var selectedExistingBroadcastID: String?
    public var selectedCaptureOutputMode: CaptureOutputMode

    public init(
        selectedSidebarItem: MainSidebarItem,
        selectedSavedProgramDefinitionName: String?,
        selectedBroadcastSourceMode: BroadcastSourceMode,
        selectedResolution: YouTubeLiveStreamResolution,
        selectedFrameRate: YouTubeLiveStreamFrameRate,
        selectedPrivacyStatus: YouTubeLiveBroadcastPrivacyStatus,
        selectedLatencyPreference: YouTubeLiveBroadcastLatencyPreference,
        selectedExistingBroadcastID: String?,
        selectedCaptureOutputMode: CaptureOutputMode
    ) {
        self.selectedSidebarItem = selectedSidebarItem
        self.selectedSavedProgramDefinitionName = selectedSavedProgramDefinitionName
        self.selectedBroadcastSourceMode = selectedBroadcastSourceMode
        self.selectedResolution = selectedResolution
        self.selectedFrameRate = selectedFrameRate
        self.selectedPrivacyStatus = selectedPrivacyStatus
        self.selectedLatencyPreference = selectedLatencyPreference
        self.selectedExistingBroadcastID = selectedExistingBroadcastID
        self.selectedCaptureOutputMode = selectedCaptureOutputMode
    }
}

public extension MainWindowState {
    static var initialValue: MainWindowState {
        defaultValue
    }

    static var defaultValue: MainWindowState {
        MainWindowState(
            selectedSidebarItem: .program,
            selectedSavedProgramDefinitionName: nil,
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
