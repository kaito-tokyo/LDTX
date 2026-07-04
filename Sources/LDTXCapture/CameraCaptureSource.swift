// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreMedia
import Foundation

public struct CameraCaptureSource: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var deviceType: String
    public var modelID: String
    public var width: Int
    public var height: Int
    public var isExternal: Bool
    public var formatSummary: String
    public var linkedDeviceIDs: [String]

    public init(
        id: String,
        name: String,
        deviceType: String,
        modelID: String,
        width: Int,
        height: Int,
        isExternal: Bool,
        formatSummary: String,
        linkedDeviceIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.modelID = modelID
        self.width = width
        self.height = height
        self.isExternal = isExternal
        self.formatSummary = formatSummary
        self.linkedDeviceIDs = linkedDeviceIDs
    }
}

public struct AudioCaptureSource: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var deviceType: String
    public var modelID: String
    public var isExternal: Bool
    public var formatSummary: String
    public var linkedDeviceIDs: [String]

    public init(
        id: String,
        name: String,
        deviceType: String,
        modelID: String,
        isExternal: Bool,
        formatSummary: String,
        linkedDeviceIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.modelID = modelID
        self.isExternal = isExternal
        self.formatSummary = formatSummary
        self.linkedDeviceIDs = linkedDeviceIDs
    }
}

public enum CameraCaptureSampleKind: Sendable, Equatable {
    case video
    case audio
}

public enum CameraCaptureServiceError: Error, Equatable, LocalizedError {
    case cameraAccessDenied
    case microphoneAccessDenied
    case cameraNotFound(String)
    case audioDeviceNotFound(String)
    case cannotAddVideoInput
    case cannotAddAudioInput
    case cannotAddVideoOutput
    case cannotAddAudioOutput
    case unsupportedVideoPixelFormat(String)

    public var errorDescription: String? {
        switch self {
        case .cameraAccessDenied:
            "Camera access was not granted."
        case .microphoneAccessDenied:
            "Microphone access was not granted."
        case let .cameraNotFound(cameraID):
            "Camera \(cameraID) was not found."
        case let .audioDeviceNotFound(audioDeviceID):
            "Audio device \(audioDeviceID) was not found."
        case .cannotAddVideoInput:
            "The selected camera could not be added to the capture session."
        case .cannotAddAudioInput:
            "The microphone could not be added to the capture session."
        case .cannotAddVideoOutput:
            "Video sample output could not be added to the capture session."
        case .cannotAddAudioOutput:
            "Audio sample output could not be added to the capture session."
        case let .unsupportedVideoPixelFormat(pixelFormat):
            "The capture output does not support the required video pixel format: \(pixelFormat)."
        }
    }
}
