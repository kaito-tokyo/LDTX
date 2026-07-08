// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXYouTube
import Observation

@MainActor
@Observable
public final class OutputDestinationModel {
    public var selectedResolution: YouTubeLiveStreamResolution
    public var selectedFrameRate: YouTubeLiveStreamFrameRate
    public var selectedExistingBroadcastID: String?
    public var selectedCaptureOutputMode: CaptureOutputMode
    public var streamTitle: String
    public var streamDescription: String
    public var usesTemporaryStream: Bool
    public var prefersColorPreview: Bool

    public init(
        selectedResolution: YouTubeLiveStreamResolution = .p1080,
        selectedFrameRate: YouTubeLiveStreamFrameRate = .fps60,
        selectedExistingBroadcastID: String? = nil,
        selectedCaptureOutputMode: CaptureOutputMode = .youtube,
        streamTitle: String = "LDTX",
        streamDescription: String = "",
        usesTemporaryStream: Bool = true,
        prefersColorPreview: Bool = false
    ) {
        self.selectedResolution = selectedResolution
        self.selectedFrameRate = selectedFrameRate
        self.selectedExistingBroadcastID = selectedExistingBroadcastID
        self.selectedCaptureOutputMode = selectedCaptureOutputMode
        self.streamTitle = streamTitle
        self.streamDescription = streamDescription
        self.usesTemporaryStream = usesTemporaryStream
        self.prefersColorPreview = prefersColorPreview
    }
}
