// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram

enum BroadcastSourceMode: String, CaseIterable, Identifiable {
    case createNew
    case useExisting

    var id: String { rawValue }
}

enum CaptureOutputMode: String, CaseIterable, Identifiable {
    case youtube
    case record
    case youtubeAndRecord

    var id: String { rawValue }

    var streamsToYouTube: Bool {
        self == .youtube || self == .youtubeAndRecord
    }

    var recordsLocally: Bool {
        self == .record || self == .youtubeAndRecord
    }
}

enum ProgramDefinition: Sendable {
    case fillSolidColor
    case fillLinearGradient
    case fillRadialGradient
    case fillConicGradient
    case inputCameraDevice
    case testPattern
    case composite

    func usesInputCameraDevice(composite: CompositeProgramDefinition) -> Bool {
        switch self {
        case .inputCameraDevice:
            true
        case .composite:
            composite.steps.contains { $0.component.definition.usesInputCameraDevice }
        default:
            false
        }
    }

    func usesInputAudioDevice(composite: CompositeProgramDefinition) -> Bool {
        switch self {
        case .composite:
            composite.audioChannels.contains { $0.component.definition.usesInputAudioDevice }
        default:
            false
        }
    }
}
