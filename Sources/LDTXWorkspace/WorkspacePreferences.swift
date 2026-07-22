// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

public struct WorkspacePreferences: Codable, Equatable, Sendable {
    public var programPreferences: ProgramPreferences
    public var physicalDeviceIDsByInputDeviceID: [String: String]
    public var inputCameraDeviceMappings: [String: String]
    public var inputAudioDeviceMappings: [String: String]
    public var inputAudioMonitorChannelKeys: Set<String>
    public var selectedProgramName: String?
    public var output: WorkspaceOutputPreferences

    public init(
        programPreferences: ProgramPreferences = ProgramPreferences(),
        physicalDeviceIDsByInputDeviceID: [String: String] = [:],
        inputCameraDeviceMappings: [String: String] = [:],
        inputAudioDeviceMappings: [String: String] = [:],
        inputAudioMonitorChannelKeys: Set<String> = [],
        selectedProgramName: String? = nil,
        output: WorkspaceOutputPreferences = WorkspaceOutputPreferences()
    ) {
        self.programPreferences = programPreferences
        self.physicalDeviceIDsByInputDeviceID = physicalDeviceIDsByInputDeviceID
        self.inputCameraDeviceMappings = inputCameraDeviceMappings
        self.inputAudioDeviceMappings = inputAudioDeviceMappings
        self.inputAudioMonitorChannelKeys = inputAudioMonitorChannelKeys
        self.selectedProgramName = selectedProgramName
        self.output = output
    }
}

public struct WorkspaceOutputPreferences: Codable, Equatable, Sendable {
    public var captureOutputMode: String
    public var existingBroadcastID: String?
    public var streamTitle: String
    public var streamDescription: String
    public var prefersColorPreview: Bool
    public var localOutputBaseDirectoryPath: String?
    public var recordingEnabled: Bool?
    public var youtubeEnabled: Bool?

    public init(
        captureOutputMode: String = "youtube",
        existingBroadcastID: String? = nil,
        streamTitle: String = "LDTX",
        streamDescription: String = "",
        prefersColorPreview: Bool = false,
        localOutputBaseDirectoryPath: String? = nil,
        recordingEnabled: Bool? = nil,
        youtubeEnabled: Bool? = nil
    ) {
        self.captureOutputMode = captureOutputMode
        self.existingBroadcastID = existingBroadcastID
        self.streamTitle = streamTitle
        self.streamDescription = streamDescription
        self.prefersColorPreview = prefersColorPreview
        self.localOutputBaseDirectoryPath = localOutputBaseDirectoryPath
        self.recordingEnabled = recordingEnabled
        self.youtubeEnabled = youtubeEnabled
    }
}
