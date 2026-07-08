// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRendering
import LDTXVideoComposition
import LDTXWorkspace
import LDTXYouTube

public let programWorldCanvasSize = (width: 1_920, height: 1_080)

public func captureTargetSize(for resolution: YouTubeLiveStreamResolution) -> (width: Int, height: Int) {
    switch resolution {
    case .p240:
        (426, 240)
    case .p360:
        (640, 360)
    case .p480:
        (854, 480)
    case .p720:
        (1_280, 720)
    case .p1080:
        (1_920, 1_080)
    case .p1440:
        (2_560, 1_440)
    case .p2160:
        (3_840, 2_160)
    }
}

public func mappedInputCameraDeviceIDs(
    for definition: ProgramDefinition,
    composite: CompositeProgramDefinition,
    workspaceInputDevices: [WorkspaceInputDeviceRecord] = [],
    inputCameraDeviceMappings: [String: String]
) -> [String: String] {
    var mappings: [String: String] = [:]
    let physicalIDsByInputDeviceID = workspaceInputDevices.physicalDeviceIDsByID(kind: .video)
    switch definition {
    case .inputCameraDevice:
        let key = BuiltInProgramDefinition.inputCameraDevice.rawValue
        if let cameraID = inputCameraDeviceMappings[key], !cameraID.isEmpty {
            mappings[key] = cameraID
        }
    case .composite:
        for step in composite.steps {
            guard case let .inputCameraDevice(payload) = step.component else {
                continue
            }
            let key = composite.inputCameraDeviceMappingKey(for: step)
            if let inputDeviceID = payload.inputDeviceID,
               let cameraID = physicalIDsByInputDeviceID[inputDeviceID] {
                mappings[key] = cameraID
            } else if let cameraID = resolvedInputMappingValue(
                key: key,
                legacyKey: composite.legacyInputCameraDeviceMappingKey(for: step),
                mappings: inputCameraDeviceMappings
            ) {
                mappings[key] = cameraID
            }
        }
    default:
        break
    }
    return mappings
}

public func inputCameraDeviceMappingKeys(
    for definition: ProgramDefinition,
    composite: CompositeProgramDefinition
) -> [String] {
    switch definition {
    case .inputCameraDevice:
        [BuiltInProgramDefinition.inputCameraDevice.rawValue]
    case .composite:
        composite.steps
            .filter { $0.component.definition.usesInputCameraDevice }
            .map { composite.inputCameraDeviceMappingKey(for: $0) }
    default:
        []
    }
}

public func programVideoPTSInputKey(
    for definition: ProgramDefinition,
    composite: CompositeProgramDefinition
) -> String? {
    let keys = inputCameraDeviceMappingKeys(for: definition, composite: composite)
    guard !keys.isEmpty else {
        return nil
    }
    return keys.first
}

public func programAudioDriverKey(
    for definition: ProgramDefinition,
    composite: CompositeProgramDefinition,
    audioChannels: [ProgramAudioChannel]? = nil
) -> String? {
    let resolvedAudioChannels = audioChannels ?? composite.audioChannels
    let keys = audioChannelKeys(for: definition, audioChannels: resolvedAudioChannels)
    guard !keys.isEmpty else {
        return nil
    }
    if case .composite = definition,
       let selectedKey = composite.programAudioPTSInputKey,
       let resolvedKey = resolvedAudioChannels.resolvedAudioChannelKey(forStoredKey: selectedKey),
       keys.contains(resolvedKey) {
        return resolvedKey
    }
    return nil
}

public func audioChannelKeys(
    for definition: ProgramDefinition,
    composite: CompositeProgramDefinition
) -> [String] {
    audioChannelKeys(for: definition, audioChannels: composite.audioChannels)
}

public func audioChannelKeys(
    for definition: ProgramDefinition,
    audioChannels: [ProgramAudioChannel]
) -> [String] {
    guard case .composite = definition else {
        return []
    }
    return audioChannels.map { audioChannels.audioChannelKey(for: $0) }
}

public func mappedInputAudioDeviceIDs(
    for definition: ProgramDefinition,
    composite: CompositeProgramDefinition,
    audioChannels: [ProgramAudioChannel]? = nil,
    workspaceInputDevices: [WorkspaceInputDeviceRecord] = [],
    inputAudioDeviceMappings: [String: String]
) -> [String: String] {
    guard case .composite = definition else {
        return [:]
    }

    let resolvedAudioChannels = audioChannels ?? composite.audioChannels
    var mappings: [String: String] = [:]
    let physicalIDsByInputDeviceID = workspaceInputDevices.physicalDeviceIDsByID(kind: .audio)
    let inputAudioDeviceChannels = resolvedAudioChannels.filter {
        $0.component.definition.usesInputAudioDevice
    }
    for channel in inputAudioDeviceChannels {
        let key = resolvedAudioChannels.inputAudioDeviceMappingKey(for: channel)
        if case let .inputAudioDevice(payload) = channel.component,
           let inputDeviceID = payload.inputDeviceID,
           let audioDeviceID = physicalIDsByInputDeviceID[inputDeviceID] {
            mappings[key] = audioDeviceID
        } else if let audioDeviceID = resolvedInputMappingValue(
            key: key,
            legacyKey: resolvedAudioChannels.legacyAudioChannelKey(for: channel),
            mappings: inputAudioDeviceMappings
        ) {
            mappings[key] = audioDeviceID
        }
    }
    return mappings
}

public func backgroundRemovalInputCameraDeviceKeys(
    for definition: ProgramDefinition,
    composite: CompositeProgramDefinition,
    workspaceInputDevices: [WorkspaceInputDeviceRecord] = []
) -> Set<String> {
    switch definition {
    case .composite:
        var keys: Set<String> = []
        let inputDevicesByID = Dictionary(
            uniqueKeysWithValues: workspaceInputDevices.map { ($0.id, $0) }
        )
        for step in composite.steps {
            guard case let .inputCameraDevice(payload) = step.component else {
                continue
            }
            guard let inputDeviceID = payload.inputDeviceID,
                  inputDevicesByID[inputDeviceID]?.backgroundRemovalPolicy == .enabled else {
                continue
            }
            let key = composite.inputCameraDeviceMappingKey(for: step)
            keys.insert(key)
        }
        return keys
    default:
        return []
    }
}

public func inputCameraColorRangeOverrides(
    for definition: ProgramDefinition,
    composite: CompositeProgramDefinition,
    workspaceInputDevices: [WorkspaceInputDeviceRecord] = []
) -> [String: CameraInputColorRangeOverride] {
    switch definition {
    case .composite:
        var colorRanges: [String: CameraInputColorRangeOverride] = [:]
        let inputDevicesByID = Dictionary(
            uniqueKeysWithValues: workspaceInputDevices.map { ($0.id, $0) }
        )
        for step in composite.steps {
            guard case let .inputCameraDevice(payload) = step.component,
                  let inputDeviceID = payload.inputDeviceID,
                  let inputDevice = inputDevicesByID[inputDeviceID] else {
                continue
            }
            let key = composite.inputCameraDeviceMappingKey(for: step)
            colorRanges[key] = switch inputDevice.colorRangePolicy {
            case .unspecified:
                .unspecified
            case .videoRange:
                .videoRange
            case .fullRange:
                .fullRange
            }
        }
        return colorRanges
    default:
        return [:]
    }
}

private extension [WorkspaceInputDeviceRecord] {
    func physicalDeviceIDsByID(kind: WorkspaceInputDeviceKind) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: compactMap { inputDevice in
                guard inputDevice.kind == kind,
                      let physicalDeviceID = inputDevice.physicalDeviceID,
                      !physicalDeviceID.isEmpty else {
                    return nil
                }
                return (inputDevice.id, physicalDeviceID)
            }
        )
    }
}

private func resolvedInputMappingValue(
    key: String,
    legacyKey: String,
    mappings: [String: String]
) -> String? {
    if let mappedValue = mappings[key], !mappedValue.isEmpty {
        return mappedValue
    }
    if let mappedValue = mappings[legacyKey], !mappedValue.isEmpty {
        return mappedValue
    }
    return nil
}
