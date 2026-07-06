// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXYouTube
import Observation

@MainActor
@Observable
public final class OutputDestinationModel {
    public var selectedBroadcastSourceMode: BroadcastSourceMode
    public var selectedResolution: YouTubeLiveStreamResolution
    public var selectedFrameRate: YouTubeLiveStreamFrameRate
    public var selectedPrivacyStatus: YouTubeLiveBroadcastPrivacyStatus
    public var selectedLatencyPreference: YouTubeLiveBroadcastLatencyPreference
    public var selectedExistingBroadcastID: String?
    public var selectedCaptureOutputMode: CaptureOutputMode
    public var streamTitle: String
    public var streamDescription: String
    public var usesTemporaryStream: Bool
    public var isShowingOutputSettings: Bool

    public init(
        selectedBroadcastSourceMode: BroadcastSourceMode = .createNew,
        selectedResolution: YouTubeLiveStreamResolution = .p1080,
        selectedFrameRate: YouTubeLiveStreamFrameRate = .fps60,
        selectedPrivacyStatus: YouTubeLiveBroadcastPrivacyStatus = .private,
        selectedLatencyPreference: YouTubeLiveBroadcastLatencyPreference = .low,
        selectedExistingBroadcastID: String? = nil,
        selectedCaptureOutputMode: CaptureOutputMode = .youtube,
        streamTitle: String = "LDTX",
        streamDescription: String = "",
        usesTemporaryStream: Bool = true,
        isShowingOutputSettings: Bool = false
    ) {
        self.selectedBroadcastSourceMode = selectedBroadcastSourceMode
        self.selectedResolution = selectedResolution
        self.selectedFrameRate = selectedFrameRate
        self.selectedPrivacyStatus = selectedPrivacyStatus
        self.selectedLatencyPreference = selectedLatencyPreference
        self.selectedExistingBroadcastID = selectedExistingBroadcastID
        self.selectedCaptureOutputMode = selectedCaptureOutputMode
        self.streamTitle = streamTitle
        self.streamDescription = streamDescription
        self.usesTemporaryStream = usesTemporaryStream
        self.isShowingOutputSettings = isShowingOutputSettings
    }
}
