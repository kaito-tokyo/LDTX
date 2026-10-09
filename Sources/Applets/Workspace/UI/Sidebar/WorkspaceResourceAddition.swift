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
    case .device: "Add Audio Device"
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
  func make(id: UInt64, name: String) -> Ldtx_Workspace_V4_VideoComponentWrapper {
    switch self {
    case .vfxSource: WorkspaceResourceFactory.makeVFXSource(id: id, name: name)
    case .solidColor: WorkspaceResourceFactory.makeSolidColor(id: id, name: name)
    case .linearGradient: WorkspaceResourceFactory.makeLinearGradient(id: id, name: name)
    case .radialGradient: WorkspaceResourceFactory.makeRadialGradient(id: id, name: name)
    case .conicGradient: WorkspaceResourceFactory.makeConicGradient(id: id, name: name)
    case .clock: WorkspaceResourceFactory.makeClock(id: id, name: name)
    case .testPattern: WorkspaceResourceFactory.makeTestPattern(id: id, name: name)
    }
  }
}

enum WorkspaceAddVisionKind: String, CaseIterable, Identifiable {
  case ocr = "OCR Vision"
  case createMlImageClassification = "Create ML Image Classification"
  var id: Self { self }
  var inspectorKind: WorkspaceInspectorKind {
    switch self {
    case .ocr: .ocrVision
    case .createMlImageClassification: .createMlImageClassificationVision
    }
  }
}

struct WorkspaceAddDraft: Equatable {
  var name = ""
  var physicalDeviceID: WorkspacePhysicalDeviceID?
  var componentKind: WorkspaceAddComponentKind = .vfxSource
  var videoComponentID: UInt64?
  var visionKind: WorkspaceAddVisionKind = .ocr
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
    storeService: WorkspaceStoreService, audioDiscoveryError: String? = nil
  ) -> String? {
    if storeService.isOutputActive { return "Stop output before adding a resource." }
    if sheet == .device, case .coreAudioDevice? = draft.physicalDeviceID,
      let audioDiscoveryError
    {
      return audioDiscoveryError
    }
    if sheet == .device
      && !devices.contains(where: { $0.id == draft.physicalDeviceID && $0.isAudio })
    {
      return "Select an available audio device."
    }
    if sheet == .vision {
      guard let componentID = draft.videoComponentID,
        storeService.definition.videoComponents.contains(where: { $0.internalID == componentID })
      else {
        return "Select a video component."
      }
    }
    let name = proposedName(sheet: sheet, draft: draft, devices: devices)
    if name.isEmpty { return "Enter a name." }
    if existingNames(storeService.definition).contains(name) {
      return "This name is already in use."
    }
    return nil
  }

  static func add(
    sheet: WorkspaceAddSheet, draft: WorkspaceAddDraft, devices: [WorkspaceAddDeviceOption],
    storeService: WorkspaceStoreService, audioDiscoveryError: String? = nil
  ) throws -> UInt64 {
    if let message = validationMessage(
      sheet: sheet, draft: draft, devices: devices, storeService: storeService,
      audioDiscoveryError: audioDiscoveryError)
    {
      throw AdditionError(message: message)
    }
    let id = WorkspaceResourceFactory.nextInternalID()
    let name = proposedName(sheet: sheet, draft: draft, devices: devices)
    var definition = storeService.definition
    let inspectorKind: WorkspaceInspectorKind
    switch sheet {
    case .device:
      definition.audioDevices.append(WorkspaceResourceFactory.makeAudioInput(id: id, name: name))
      inspectorKind = .audioInputDevice
    case .videoComponent:
      definition.videoComponents.append(
        draft.componentKind.make(id: id, name: name))
      inspectorKind = draft.componentKind.inspectorKind
    case .vision:
      let vision: Ldtx_Workspace_V4_VisionWrapper
      switch draft.visionKind {
      case .ocr:
        vision = WorkspaceResourceFactory.makeOcrVision(
          id: id, name: name, componentID: draft.videoComponentID!)
      case .createMlImageClassification:
        vision = WorkspaceResourceFactory.makeCreateMlImageClassificationVision(
          id: id, name: name, componentID: draft.videoComponentID!)
      }
      definition.visions.append(vision)
      inspectorKind = draft.visionKind.inspectorKind
    }
    storeService.definition = definition
    storeService.inspectorSelector = .init(kind: inspectorKind, internalID: id)
    return id
  }

  private struct AdditionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static func existingNames(_ definition: WorkspaceStoreService.WorkspaceDefinition) -> Set<
    String
  > {
    var names = Set(
      definition.audioDevices.map(\.displayName) + definition.programs.map(\.displayName))
    for component in definition.videoComponents {
      if let name = component.displayName { names.insert(name) }
    }
    for vision in definition.visions {
      if let name = vision.displayName { names.insert(name) }
    }
    return names
  }
}
