// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXWorkspaceAppletModel

enum WorkspaceAddSheet: String, Identifiable {
  case device, videoComponent, vision
  var id: Self { self }
  var title: String {
    switch self {
    case .device: "Add Input Device"
    case .videoComponent: "Add Video Component"
    case .vision: "Add Vision"
    }
  }
}

enum WorkspaceAddComponentKind: String, CaseIterable, Identifiable {
  case vfxSource = "VFX Source"
  case solidColor = "Solid Color"
  case linearGradient = "Linear Gradient"
  case radialGradient = "Radial Gradient"
  case conicGradient = "Conic Gradient"
  case clock = "Clock"
  case testPattern = "Test Pattern"
  var id: Self { self }
  var inspectorKind: WorkspaceInspectorKind {
    switch self {
    case .vfxSource: .vfxVideoComponent
    case .solidColor: .solidColorFillVideoComponent
    case .linearGradient: .linearGradientFillVideoComponent
    case .radialGradient: .radialGradientFillVideoComponent
    case .conicGradient: .conicGradientFillVideoComponent
    case .clock: .clockVideoComponent
    case .testPattern: .testPatternVideoComponent
    }
  }
  func make(id: UInt64, name: String, inputID: UInt64?) -> Ldtx_Workspace_V4_VideoComponentWrapper {
    switch self {
    case .vfxSource: WorkspaceResourceFactory.makeVFXSource(id: id, name: name, inputID: inputID!)
    case .solidColor: WorkspaceResourceFactory.makeSolidColor(id: id, name: name)
    case .linearGradient: WorkspaceResourceFactory.makeLinearGradient(id: id, name: name)
    case .radialGradient: WorkspaceResourceFactory.makeRadialGradient(id: id, name: name)
    case .conicGradient: WorkspaceResourceFactory.makeConicGradient(id: id, name: name)
    case .clock: WorkspaceResourceFactory.makeClock(id: id, name: name)
    case .testPattern: WorkspaceResourceFactory.makeTestPattern(id: id, name: name)
    }
  }
}

struct WorkspaceAddDraft: Equatable {
  var name = ""
  var physicalDeviceID: WorkspacePhysicalDeviceID?
  var componentKind: WorkspaceAddComponentKind = .vfxSource
  var videoInputID: UInt64?
}

struct WorkspaceAddDeviceOption: Identifiable {
  let id: WorkspacePhysicalDeviceID
  let name: String
  var isAudio: Bool {
    if case .coreAudioDevice = id { return true }
    return false
  }
}

@MainActor
enum WorkspaceResourceAddition {
  static func proposedName(
    sheet: WorkspaceAddSheet, draft: WorkspaceAddDraft, devices: [WorkspaceAddDeviceOption]
  ) -> String {
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if sheet == .device && name.isEmpty {
      return devices.first { $0.id == draft.physicalDeviceID }?.name
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    return name
  }

  static func validationMessage(
    sheet: WorkspaceAddSheet, draft: WorkspaceAddDraft, devices: [WorkspaceAddDeviceOption],
    uiState: WorkspaceUIState
  ) -> String? {
    if uiState.isOutputActive { return "Stop output before adding a resource." }
    if sheet == .device && !devices.contains(where: { $0.id == draft.physicalDeviceID }) {
      return "Select an available input device."
    }
    if sheet == .vision || (sheet == .videoComponent && draft.componentKind == .vfxSource) {
      if !uiState.definition.inputDevices.contains(where: {
        if case .videoDevice(let device) = $0.definition {
          return device.internalID == draft.videoInputID
        }
        return false
      }) {
        return "Select a video input device."
      }
    }
    let name = proposedName(sheet: sheet, draft: draft, devices: devices)
    if name.isEmpty { return "Enter a name." }
    if existingNames(uiState.definition).contains(name) { return "This name is already in use." }
    return nil
  }

  static func add(
    sheet: WorkspaceAddSheet, draft: WorkspaceAddDraft, devices: [WorkspaceAddDeviceOption],
    uiState: WorkspaceUIState
  ) throws -> UInt64 {
    if let message = validationMessage(
      sheet: sheet, draft: draft, devices: devices, uiState: uiState)
    {
      throw AdditionError(message: message)
    }
    let id = WorkspaceResourceFactory.nextInternalID()
    let name = proposedName(sheet: sheet, draft: draft, devices: devices)
    var definition = uiState.definition
    let inspectorKind: WorkspaceInspectorKind
    switch sheet {
    case .device:
      let isAudio = devices.first { $0.id == draft.physicalDeviceID }!.isAudio
      definition.inputDevices.append(
        isAudio
          ? WorkspaceResourceFactory.makeAudioInput(id: id, name: name)
          : WorkspaceResourceFactory.makeVideoInput(id: id, name: name))
      inspectorKind = isAudio ? .audioInputDevice : .videoInputDevice
    case .videoComponent:
      definition.videoComponents.append(
        draft.componentKind.make(id: id, name: name, inputID: draft.videoInputID))
      inspectorKind = draft.componentKind.inspectorKind
    case .vision:
      definition.visions.append(
        WorkspaceResourceFactory.makeOcrVision(id: id, name: name, inputID: draft.videoInputID!))
      inspectorKind = .ocrVision
    }
    uiState.definition = definition
    uiState.inspectorSelector = .init(kind: inspectorKind, internalID: id)
    return id
  }

  private struct AdditionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private static func existingNames(_ definition: WorkspaceUIState.WorkspaceDefinition) -> Set<
    String
  > {
    Set(
      definition.inputDevices.compactMap {
        switch $0.definition {
        case .videoDevice(let value): value.displayName
        case .audioDevice(let value): value.displayName
        case nil: nil
        }
      }
        + definition.videoComponents.compactMap {
          switch $0.definition {
          case .vfxSource(let value): value.displayName
          case .solidColorFill(let value): value.displayName
          case .linearGradientFill(let value): value.displayName
          case .radialGradientFill(let value): value.displayName
          case .conicGradientFill(let value): value.displayName
          case .clock(let value): value.displayName
          case .testPattern(let value): value.displayName
          case nil: nil
          }
        }
        + definition.visions.compactMap {
          if case .ocrVision(let value) = $0.definition { return value.displayName }
          return nil
        } + definition.programs.map(\.displayName))
  }
}
