// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

/// Verifies that a decoded Workspace can be represented by the application.
///
/// This is deliberately a read boundary only. Saving preserves the exact
/// in-memory Definition and Preferences; it neither repairs nor rejects a
/// user-authored representation.
public enum WorkspaceIntegrityValidator {
  public static func validateForLoading(_ workspace: WorkspaceDefinition) throws {
    try WorkspaceResourceNameValidator.validate(workspace)
    try validateProgramNames(workspace.programs)

    let inputDevicesByID = firstValuesByKey(workspace.inputDevices, key: \.id)

    if let videoPTSMasterInputDeviceID = workspace.outputConfiguration.videoPTSMasterInputDeviceID {
      try requireInputDevice(
        videoPTSMasterInputDeviceID,
        ofKind: .video,
        in: inputDevicesByID,
        reference: "Workspace Output Configuration"
      )
    }

    for component in workspace.videoComponents {
      guard case .inputCameraDevice(let payload) = component.component,
        let inputDeviceID = payload.inputDeviceID
      else { continue }
      try requireInputDevice(
        inputDeviceID,
        ofKind: .video,
        in: inputDevicesByID,
        reference: "Video Component \(component.name)"
      )
    }

    for channel in workspace.audioChannels {
      guard case .inputAudioDevice(let payload) = channel.component,
        let inputDeviceID = payload.inputDeviceID
      else { continue }
      try requireInputDevice(
        inputDeviceID,
        ofKind: .audio,
        in: inputDevicesByID,
        reference: "Audio Channel \(channel.name)"
      )
    }

    for program in workspace.programs {
      for (canvasName, composite) in [
        ("Landscape", program.landscape.composite),
        ("Portrait", program.portrait.composite),
      ] {
        var audioChannelNames = Set<String>()
        for channel in composite.audioChannels {
          guard audioChannelNames.insert(channel.name).inserted else {
            throw WorkspaceIntegrityError.duplicateCanvasAudioChannelName(
              program: program.name,
              canvas: canvasName,
              channel: channel.name)
          }
        }
        for step in composite.steps {
          guard case .inputCameraDevice(let payload) = step.component,
            let inputDeviceID = payload.inputDeviceID,
            !inputDeviceID.isEmpty
          else { continue }
          let displayName = step.displayName ?? step.name
          let reference = "\(canvasName) Camera \(displayName) in \(program.name)"
          try requireInputDevice(
            inputDeviceID,
            ofKind: .video,
            in: inputDevicesByID,
            reference: reference
          )
        }
        for channel in composite.audioChannels {
          guard case .inputAudioDevice(let payload) = channel.component,
            let inputDeviceID = payload.inputDeviceID
          else { continue }
          try requireInputDevice(
            inputDeviceID,
            ofKind: .audio,
            in: inputDevicesByID,
            reference: "\(canvasName) Audio Channel \(channel.name) in \(program.name)"
          )
        }
      }
    }

    for vision in workspace.visions {
      if case .inputDevice(let name) = vision.source {
        try requireInputDevice(
          name,
          ofKind: .video,
          in: inputDevicesByID,
          reference: "Vision \(vision.name)"
        )
      }
    }
  }

  /// Validates the persisted Workspace and its colocated Preferences as one
  /// document. Preference references are meaningful only with the Workspace
  /// Definition they were saved alongside.
  public static func validateForLoading(
    _ workspace: WorkspaceDefinition,
    preferences: WorkspacePreferences
  ) throws {
    try validateForLoading(workspace)
    if let selectedProgramName = preferences.selectedProgramName,
      !workspace.programs.contains(where: { $0.name == selectedProgramName })
    {
      throw WorkspaceIntegrityError.missingReference(
        owner: "Workspace Preferences",
        reference: selectedProgramName
      )
    }
    let programNames = Set(workspace.programs.map(\.name))
    let componentNames = Set(workspace.videoComponents.map(\.name))
    let videoInputDeviceNames = Set(
      workspace.inputDevices.lazy
        .filter { $0.kind == .video }
        .map(\.name)
    )
    let videoLayerSourceNames = componentNames.union(videoInputDeviceNames)
    for programPreferences in [
      preferences.programPreferences, preferences.portraitProgramPreferences,
    ] {
      for (programName, layers) in programPreferences.videoLayersByProgramName {
        guard programNames.contains(programName) else {
          throw WorkspaceIntegrityError.missingReference(
            owner: "Video Layer Preferences",
            reference: programName
          )
        }
        for layer in layers where !videoLayerSourceNames.contains(layer.componentName) {
          throw WorkspaceIntegrityError.missingReference(
            owner: "Video Layers for \(programName)",
            reference: layer.componentName
          )
        }
      }
    }
  }

  private static func requireInputDevice(
    _ id: String,
    ofKind expectedKind: WorkspaceInputDeviceKind,
    in inputDevicesByID: [String: WorkspaceInputDeviceRecord],
    reference: String
  ) throws {
    guard let inputDevice = inputDevicesByID[id] else {
      throw WorkspaceIntegrityError.missingReference(owner: reference, reference: id)
    }
    guard inputDevice.kind == expectedKind else {
      throw WorkspaceIntegrityError.incompatibleInputDevice(
        owner: reference,
        inputDeviceID: id,
        expectedKind: expectedKind,
        actualKind: inputDevice.kind
      )
    }
  }

  private static func validateProgramNames(_ programs: [SavedProgramDefinitionRecord]) throws {
    var seen = Set<String>()
    for program in programs {
      guard !program.name.isEmpty else {
        throw WorkspaceIntegrityError.emptyProgramName
      }
      guard seen.insert(program.name).inserted else {
        throw WorkspaceIntegrityError.duplicateProgramName(program.name)
      }
    }
  }
}

public enum WorkspaceIntegrityError: LocalizedError, Equatable, Sendable {
  case emptyProgramName
  case duplicateProgramName(String)
  case duplicateCanvasAudioChannelName(program: String, canvas: String, channel: String)
  case missingReference(owner: String, reference: String)
  case incompatibleInputDevice(
    owner: String,
    inputDeviceID: String,
    expectedKind: WorkspaceInputDeviceKind,
    actualKind: WorkspaceInputDeviceKind
  )

  public var errorDescription: String? {
    switch self {
    case .emptyProgramName:
      "Program names must not be empty."
    case .duplicateProgramName(let name):
      "Program name \"\(name)\" is used more than once. Program names must be unique."
    case .duplicateCanvasAudioChannelName(let program, let canvas, let channel):
      "\(canvas) Canvas in Program \"\(program)\" contains more than one Audio Channel named \"\(channel)\". Audio Channel names must be unique within a Canvas."
    case .missingReference(let owner, let reference):
      "\(owner) refers to missing resource \"\(reference)\"."
    case .incompatibleInputDevice(let owner, let inputDeviceID, let expectedKind, let actualKind):
      "\(owner) requires a \(expectedKind.rawValue) input device, but \"\(inputDeviceID)\" is \(actualKind.rawValue)."
    }
  }
}

private func firstValuesByKey<Value>(_ values: [Value], key: (Value) -> String) -> [String: Value] {
  var result: [String: Value] = [:]
  for value in values where result[key(value)] == nil {
    result[key(value)] = value
  }
  return result
}
