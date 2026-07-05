// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import LDTXYouTube

let programWorldCanvasSize = (width: 1_920, height: 1_080)

func captureTargetSize(for resolution: YouTubeLiveStreamResolution) -> (width: Int, height: Int) {
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

func mappedInputCameraDeviceIDs(
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
            } else if let cameraID = inputCameraDeviceMappings[key], !cameraID.isEmpty {
                mappings[key] = cameraID
            }
        }
    default:
        break
    }
    return mappings
}

func inputCameraDeviceMappingKeys(
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

func programVideoPTSInputKey(
    for definition: ProgramDefinition,
    composite: CompositeProgramDefinition
) -> String? {
    let keys = inputCameraDeviceMappingKeys(for: definition, composite: composite)
    guard !keys.isEmpty else {
        return nil
    }
    if case .composite = definition,
       let selectedKey = composite.programVideoPTSInputKey,
       keys.contains(selectedKey) {
        return selectedKey
    }
    return keys.first
}

func programAudioDriverKey(
    for definition: ProgramDefinition,
    composite: CompositeProgramDefinition
) -> String? {
    let keys = audioChannelKeys(for: definition, composite: composite)
    guard !keys.isEmpty else {
        return nil
    }
    if case .composite = definition,
       let selectedKey = composite.programAudioPTSInputKey,
       keys.contains(selectedKey) {
        return selectedKey
    }
    return nil
}

func audioChannelKeys(
    for definition: ProgramDefinition,
    composite: CompositeProgramDefinition
) -> [String] {
    guard case .composite = definition else {
        return []
    }
    return composite.audioChannels.map { composite.audioChannelKey(for: $0) }
}

func mappedInputAudioDeviceIDs(
    for definition: ProgramDefinition,
    composite: CompositeProgramDefinition,
    workspaceInputDevices: [WorkspaceInputDeviceRecord] = [],
    inputAudioDeviceMappings: [String: String]
) -> [String: String] {
    guard case .composite = definition else {
        return [:]
    }

    var mappings: [String: String] = [:]
    let physicalIDsByInputDeviceID = workspaceInputDevices.physicalDeviceIDsByID(kind: .audio)
    let inputAudioDeviceChannels = composite.audioChannels.filter {
        $0.component.definition.usesInputAudioDevice
    }
    for channel in inputAudioDeviceChannels {
        let key = composite.inputAudioDeviceMappingKey(for: channel)
        if case let .inputAudioDevice(payload) = channel.component,
           let inputDeviceID = payload.inputDeviceID,
           let audioDeviceID = physicalIDsByInputDeviceID[inputDeviceID] {
            mappings[key] = audioDeviceID
        } else if let audioDeviceID = inputAudioDeviceMappings[key], !audioDeviceID.isEmpty {
            mappings[key] = audioDeviceID
        }
    }
    return mappings
}

func backgroundRemovalInputCameraDeviceKeys(
    for definition: ProgramDefinition,
    composite: CompositeProgramDefinition
) -> Set<String> {
    switch definition {
    case .composite:
        var keys: Set<String> = []
        for step in composite.steps {
            guard case let .inputCameraDevice(payload) = step.component,
                  payload.removesBackground else {
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
