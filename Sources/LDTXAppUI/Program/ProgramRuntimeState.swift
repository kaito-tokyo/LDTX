// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRendering
import LDTXVideoComposition
import LDTXWorkspace

public let programWorldCanvasSize = (width: 1_920, height: 1_080)

public func captureTargetSize(for resolution: OutputVideoResolution) -> (
  width: Int, height: Int
) {
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
  composite: CompositeProgramDefinition,
  workspaceInputDevices: [WorkspaceInputDeviceRecord] = [],
  inputCameraDeviceMappings: [String: String]
) -> [String: String] {
  var mappings: [String: String] = [:]
  let physicalIDsByInputDeviceID = workspaceInputDevices.physicalDeviceIDsByID(kind: .video)
  for step in composite.steps {
      guard case .inputCameraDevice(let payload) = step.component else {
        continue
      }
      let key = composite.inputCameraDeviceMappingKey(for: step)
      if let inputDeviceID = payload.inputDeviceID,
        let cameraID = physicalIDsByInputDeviceID[inputDeviceID]
      {
        mappings[key] = cameraID
      } else if let cameraID = resolvedInputMappingValue(
        key: key,
        legacyKey: composite.legacyInputCameraDeviceMappingKey(for: step),
        mappings: inputCameraDeviceMappings
      ) {
        mappings[key] = cameraID
      }
  }
  return mappings
}

public func mappedInputCameraDeviceNames(
  composite: CompositeProgramDefinition,
  workspaceInputDevices: [WorkspaceInputDeviceRecord] = []
) -> [String: String] {
  let inputDevicesByID = Dictionary(uniqueKeysWithValues: workspaceInputDevices.map { ($0.id, $0) })
  var names: [String: String] = [:]
  for step in composite.steps {
    guard case .inputCameraDevice(let payload) = step.component,
      let inputDeviceID = payload.inputDeviceID,
      let inputDevice = inputDevicesByID[inputDeviceID]
    else { continue }
    names[composite.inputCameraDeviceMappingKey(for: step)] = inputDevice.name
  }
  return names
}

public func inputCameraDeviceMappingKeys(
  composite: CompositeProgramDefinition
) -> [String] {
  composite.steps
    .filter { $0.component.definition.usesInputCameraDevice }
    .map { composite.inputCameraDeviceMappingKey(for: $0) }
}

public func programVideoPTSInputKey(
  composite: CompositeProgramDefinition,
  cameraIDsByInputKey: [String: String]
) -> String? {
  let keys = inputCameraDeviceMappingKeys(composite: composite)
  if let selectedKey = composite.programVideoPTSInputKey,
    let resolvedKey = composite.resolvedInputCameraDeviceMappingKey(forStoredKey: selectedKey),
    cameraIDsByInputKey[resolvedKey] != nil
  {
    return resolvedKey
  }
  return keys.first { cameraIDsByInputKey[$0] != nil }
}

public func audioChannelKeys(
  composite: CompositeProgramDefinition
) -> [String] {
  audioChannelKeys(audioChannels: composite.audioChannels)
}

public func audioChannelKeys(
  audioChannels: [ProgramAudioChannel]
) -> [String] {
  return audioChannels.map { audioChannels.audioChannelKey(for: $0) }
}

public func mappedInputAudioDeviceIDs(
  composite: CompositeProgramDefinition,
  audioChannels: [ProgramAudioChannel]? = nil,
  workspaceInputDevices: [WorkspaceInputDeviceRecord] = [],
  inputAudioDeviceMappings: [String: String]
) -> [String: String] {
  let resolvedAudioChannels = audioChannels ?? composite.audioChannels
  var mappings: [String: String] = [:]
  let physicalIDsByInputDeviceID = workspaceInputDevices.physicalDeviceIDsByID(kind: .audio)
  let inputAudioDeviceChannels = resolvedAudioChannels.filter {
    $0.component.definition.usesInputAudioDevice
  }
  for channel in inputAudioDeviceChannels {
    let key = resolvedAudioChannels.inputAudioDeviceMappingKey(for: channel)
    if case .inputAudioDevice(let payload) = channel.component,
      let inputDeviceID = payload.inputDeviceID,
      let audioDeviceID = physicalIDsByInputDeviceID[inputDeviceID]
    {
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

public func mappedInputAudioDeviceNames(
  composite: CompositeProgramDefinition,
  audioChannels: [ProgramAudioChannel]? = nil,
  workspaceInputDevices: [WorkspaceInputDeviceRecord] = []
) -> [String: String] {
  let resolvedAudioChannels = audioChannels ?? composite.audioChannels
  let inputDevicesByID = Dictionary(
    uniqueKeysWithValues: workspaceInputDevices.map { ($0.id, $0) }
  )
  var names: [String: String] = [:]
  for channel in resolvedAudioChannels where channel.component.definition.usesInputAudioDevice {
    let key = resolvedAudioChannels.inputAudioDeviceMappingKey(for: channel)
    guard case .inputAudioDevice(let payload) = channel.component,
      let inputDeviceID = payload.inputDeviceID,
      let inputDevice = inputDevicesByID[inputDeviceID]
    else {
      continue
    }
    names[key] = inputDevice.name
  }
  return names
}

public func backgroundRemovalInputCameraDeviceKeys(
  composite: CompositeProgramDefinition,
  workspaceInputDevices: [WorkspaceInputDeviceRecord] = []
) -> Set<String> {
  var keys: Set<String> = []
    let inputDevicesByID = Dictionary(
      uniqueKeysWithValues: workspaceInputDevices.map { ($0.id, $0) }
    )
    for step in composite.steps {
      guard case .inputCameraDevice(let payload) = step.component else {
        continue
      }
      guard let inputDeviceID = payload.inputDeviceID,
        inputDevicesByID[inputDeviceID]?.backgroundRemovalPolicy == .enabled
      else {
        continue
      }
      let key = composite.inputCameraDeviceMappingKey(for: step)
      keys.insert(key)
    }
  return keys
}

public func inputCameraColorRangeOverrides(
  composite: CompositeProgramDefinition,
  workspaceInputDevices: [WorkspaceInputDeviceRecord] = []
) -> [String: CameraInputColorRangeOverride] {
  var colorRanges: [String: CameraInputColorRangeOverride] = [:]
    let inputDevicesByID = Dictionary(
      uniqueKeysWithValues: workspaceInputDevices.map { ($0.id, $0) }
    )
    for step in composite.steps {
      guard case .inputCameraDevice(let payload) = step.component,
        let inputDeviceID = payload.inputDeviceID,
        let inputDevice = inputDevicesByID[inputDeviceID]
      else {
        continue
      }
      let key = composite.inputCameraDeviceMappingKey(for: step)
      colorRanges[key] =
        switch inputDevice.colorRangePolicy {
        case .unspecified:
          .unspecified
        case .videoRange:
          .videoRange
        case .fullRange:
          .fullRange
        }
    }
  return colorRanges
}

extension [WorkspaceInputDeviceRecord] {
  fileprivate func physicalDeviceIDsByID(kind: WorkspaceInputDeviceKind) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: compactMap { inputDevice in
        guard inputDevice.kind == kind,
          let physicalDeviceID = inputDevice.physicalDeviceID,
          !physicalDeviceID.isEmpty
        else {
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
