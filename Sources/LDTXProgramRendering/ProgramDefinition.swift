// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram

public enum ProgramDefinition: Sendable {
    case fillSolidColor
    case fillLinearGradient
    case fillRadialGradient
    case fillConicGradient
    case inputCameraDevice
    case testPattern
    case composite

    public func usesInputCameraDevice(composite: CompositeProgramDefinition) -> Bool {
        switch self {
        case .inputCameraDevice:
            true
        case .composite:
            composite.steps.contains { $0.component.definition.usesInputCameraDevice }
        default:
            false
        }
    }

    public func usesInputAudioDevice(composite: CompositeProgramDefinition) -> Bool {
        switch self {
        case .composite:
            composite.audioChannels.contains { $0.component.definition.usesInputAudioDevice }
        default:
            false
        }
    }
}
