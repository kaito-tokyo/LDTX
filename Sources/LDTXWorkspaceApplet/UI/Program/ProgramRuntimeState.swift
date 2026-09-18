// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRendering
import LDTXVideoComposition
import LDTXWorkspace

public let programWorldCanvasSize = (width: 1_920, height: 1_080)

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
    } else if let cameraID = inputCameraDeviceMappings[key], !cameraID.isEmpty {
      mappings[key] = cameraID
    }
  }
  return mappings
}

public func mappedInputCameraDeviceNames(
  composite: CompositeProgramDefinition,
  workspaceInputDevices: [WorkspaceInputDeviceRecord] = []
) -> [String: String] {
  let inputDevicesByID = firstInputDevicesByID(workspaceInputDevices)
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

public func workspaceVideoPTSMasterCameraID(
  masterInputDeviceID: String?,
  workspaceInputDevices: [WorkspaceInputDeviceRecord]
) -> String? {
  guard let masterInputDeviceID,
    let inputDevice = workspaceInputDevices.first(where: { $0.id == masterInputDeviceID }),
    inputDevice.kind == .video
  else { return nil }
  return inputDevice.physicalDeviceID
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
    } else if let audioDeviceID = inputAudioDeviceMappings[key], !audioDeviceID.isEmpty {
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
  let inputDevicesByID = firstInputDevicesByID(workspaceInputDevices)
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
  composite: CompositeProgramDefinition
) -> Set<String> {
  var keys: Set<String> = []
  for step in composite.steps {
    guard case .inputCameraDevice(let payload) = step.component else {
      continue
    }
    guard payload.removesBackground else {
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
  let inputDevicesByID = firstInputDevicesByID(workspaceInputDevices)
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
    var physicalDeviceIDs: [String: String] = [:]
    for inputDevice in self where inputDevice.kind == kind {
      guard let physicalDeviceID = inputDevice.physicalDeviceID,
        !physicalDeviceID.isEmpty,
        physicalDeviceIDs[inputDevice.id] == nil
      else { continue }
      physicalDeviceIDs[inputDevice.id] = physicalDeviceID
    }
    return physicalDeviceIDs
  }
}

private func firstInputDevicesByID(
  _ inputDevices: [WorkspaceInputDeviceRecord]
) -> [String: WorkspaceInputDeviceRecord] {
  var inputDevicesByID: [String: WorkspaceInputDeviceRecord] = [:]
  for inputDevice in inputDevices where inputDevicesByID[inputDevice.id] == nil {
    inputDevicesByID[inputDevice.id] = inputDevice
  }
  return inputDevicesByID
}
