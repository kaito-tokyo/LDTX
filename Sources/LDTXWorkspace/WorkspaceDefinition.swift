// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

public struct WorkspaceDefinition: Codable, Equatable, Sendable {
  public var name: String
  public var programs: [SavedProgramDefinitionRecord]
  public var inputDevices: [WorkspaceInputDeviceRecord]
  public var audioChannels: [ProgramAudioChannel]
  public var visions: [WorkspaceVisionDefinition]
  public var videoComponents: [WorkspaceVideoComponentRecord]
  public var outputConfiguration: WorkspaceOutputConfiguration

  public static func == (lhs: WorkspaceDefinition, rhs: WorkspaceDefinition) -> Bool {
    lhs.name == rhs.name && lhs.programs == rhs.programs && lhs.inputDevices == rhs.inputDevices
      && lhs.audioChannels == rhs.audioChannels && lhs.visions == rhs.visions
      && lhs.videoComponents == rhs.videoComponents
      && lhs.outputConfiguration == rhs.outputConfiguration
  }

  enum CodingKeys: String, CodingKey {
    case name
    case programs
    case inputDevices
    case audioChannels
    case visions
    case videoComponents
    case outputConfiguration
  }

  public init(
    name: String = "Untitled Workspace",
    programs: [SavedProgramDefinitionRecord] = [],
    inputDevices: [WorkspaceInputDeviceRecord] = [],
    audioChannels: [ProgramAudioChannel] = [],
    visions: [WorkspaceVisionDefinition] = [],
    videoComponents: [WorkspaceVideoComponentRecord] = [],
    outputConfiguration: WorkspaceOutputConfiguration = WorkspaceOutputConfiguration()
  ) {
    self.name = name
    self.programs = programs
    self.inputDevices = inputDevices
    self.audioChannels = audioChannels
    self.visions = visions
    self.videoComponents = videoComponents
    self.outputConfiguration = outputConfiguration
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Workspace"
    programs =
      try container.decodeIfPresent([SavedProgramDefinitionRecord].self, forKey: .programs) ?? []
    inputDevices =
      try container.decodeIfPresent([WorkspaceInputDeviceRecord].self, forKey: .inputDevices) ?? []
    audioChannels =
      try container.decodeIfPresent([ProgramAudioChannel].self, forKey: .audioChannels) ?? []
    visions =
      try container.decodeIfPresent([WorkspaceVisionDefinition].self, forKey: .visions) ?? []
    videoComponents =
      try container.decodeIfPresent([WorkspaceVideoComponentRecord].self, forKey: .videoComponents)
      ?? []
    outputConfiguration =
      try container.decodeIfPresent(
        WorkspaceOutputConfiguration.self,
        forKey: .outputConfiguration
      ) ?? WorkspaceOutputConfiguration()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(programs, forKey: .programs)
    try container.encode(inputDevices, forKey: .inputDevices)
    try container.encode(audioChannels, forKey: .audioChannels)
    try container.encode(visions, forKey: .visions)
    try container.encode(videoComponents, forKey: .videoComponents)
    try container.encode(outputConfiguration, forKey: .outputConfiguration)
  }
}

public enum WorkspaceOutputProfileID: String, Codable, CaseIterable, Sendable {
  case sdr1080p60 = "sdr-1080p60"
}

public struct WorkspaceOutputConfiguration: Codable, Equatable, Sendable {
  /// The Canvas preset that selects the output encoding contract.
  public var profileID: WorkspaceOutputProfileID?
  public var canvasWidth: Int
  public var canvasHeight: Int
  public var frameRate: Int
  public var videoBitRate: Int
  /// The Workspace Video Input Device that supplies output PTS. `nil` uses the host clock.
  public var videoPTSMasterInputDeviceID: String?

  public init(
    profileID: WorkspaceOutputProfileID? = .sdr1080p60,
    canvasWidth: Int = 1_920,
    canvasHeight: Int = 1_080,
    frameRate: Int = 60,
    videoBitRate: Int = 6_000_000,
    videoPTSMasterInputDeviceID: String? = nil
  ) {
    self.profileID = profileID
    self.canvasWidth = canvasWidth
    self.canvasHeight = canvasHeight
    self.frameRate = frameRate
    self.videoBitRate = videoBitRate
    self.videoPTSMasterInputDeviceID = videoPTSMasterInputDeviceID
  }

  public var isSupportedOutputProfile: Bool {
    profileID == .sdr1080p60
      && canvasWidth == 1_920
      && canvasHeight == 1_080
      && frameRate == 60
      && videoBitRate > 0
      && videoBitRate <= 62_500_000
  }

  private enum CodingKeys: String, CodingKey {
    case profileID, canvasWidth, canvasHeight, frameRate, videoBitRate,
      videoPTSMasterInputDeviceID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    canvasWidth = try container.decodeIfPresent(Int.self, forKey: .canvasWidth) ?? 1_920
    canvasHeight = try container.decodeIfPresent(Int.self, forKey: .canvasHeight) ?? 1_080
    frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate) ?? 60
    videoBitRate = try container.decodeIfPresent(Int.self, forKey: .videoBitRate) ?? 6_000_000
    videoPTSMasterInputDeviceID = try container.decodeIfPresent(
      String.self, forKey: .videoPTSMasterInputDeviceID
    )
    profileID = try container.decodeIfPresent(WorkspaceOutputProfileID.self, forKey: .profileID)
  }

  public func normalizedForOutputPreset() -> WorkspaceOutputConfiguration? {
    guard isSupportedOutputProfile else { return nil }
    return self
  }

  public static let sdr1080p60 = WorkspaceOutputConfiguration(
    profileID: .sdr1080p60,
    canvasWidth: 1_920,
    canvasHeight: 1_080,
    frameRate: 60, videoBitRate: 6_000_000
  )
}

public struct WorkspaceVideoComponentRecord: Codable, Equatable, Sendable, Identifiable {
  public var name: String
  public var component: ProgramComponent

  public var id: String { name }

  public init(
    name: String,
    inputDeviceID: String? = nil,
    sourceCropTop: Float = 0,
    sourceCropRight: Float = 0,
    sourceCropBottom: Float = 0,
    sourceCropLeft: Float = 0,
    removesBackground: Bool = false
  ) {
    self.name = name
    self.component = .inputCameraDevice(
      InputDeviceComponent(
        inputDeviceID: inputDeviceID,
        sourceCropTop: sourceCropTop,
        sourceCropRight: sourceCropRight,
        sourceCropBottom: sourceCropBottom,
        sourceCropLeft: sourceCropLeft,
        removesBackground: removesBackground
      ))
  }

  public init(name: String, component: ProgramComponent) {
    self.name = name
    self.component = component
  }

  public var inputDeviceID: String? {
    get { inputDeviceComponent?.inputDeviceID }
    set { updateInputDeviceComponent { $0.inputDeviceID = newValue } }
  }
  public var sourceCropTop: Float {
    get { inputDeviceComponent?.sourceCropTop ?? 0 }
    set { updateInputDeviceComponent { $0.sourceCropTop = newValue } }
  }
  public var sourceCropRight: Float {
    get { inputDeviceComponent?.sourceCropRight ?? 0 }
    set { updateInputDeviceComponent { $0.sourceCropRight = newValue } }
  }
  public var sourceCropBottom: Float {
    get { inputDeviceComponent?.sourceCropBottom ?? 0 }
    set { updateInputDeviceComponent { $0.sourceCropBottom = newValue } }
  }
  public var sourceCropLeft: Float {
    get { inputDeviceComponent?.sourceCropLeft ?? 0 }
    set { updateInputDeviceComponent { $0.sourceCropLeft = newValue } }
  }
  public var removesBackground: Bool {
    get { inputDeviceComponent?.removesBackground ?? false }
    set { updateInputDeviceComponent { $0.removesBackground = newValue } }
  }

  private var inputDeviceComponent: InputDeviceComponent? {
    guard case .inputCameraDevice(let payload) = component else { return nil }
    return payload
  }

  private mutating func updateInputDeviceComponent(_ update: (inout InputDeviceComponent) -> Void) {
    guard case .inputCameraDevice(var payload) = component else { return }
    update(&payload)
    component = .inputCameraDevice(payload)
  }
}

public enum WorkspaceVideoComponentResolver {
  public static let coordinateWidth: Float = 1_920
  public static let coordinateHeight: Float = 1_080

  public static func applying(
    _ videoComponents: [WorkspaceVideoComponentRecord],
    layers: [VideoLayerPreference],
    to composite: CompositeProgramDefinition
  ) -> CompositeProgramDefinition {
    let existingByName = firstProgramStepsByName(composite.steps)
    let componentsByName = firstVideoComponentsByName(videoComponents)
    var resolved = composite
    resolved.steps = layers.compactMap { layer in
      guard
        var step = existingByName[layer.componentName]
          ?? componentsByName[layer.componentName].map({
            CompositeProgramStep(displayName: layer.componentName, component: $0)
          })
      else { return nil }

      if let definitionComponent = componentsByName[layer.componentName] {
        step.component = definitionComponent
      }
      switch step.component {
      case .inputCameraDevice(var payload):
        payload.destinationX = layer.destinationX
        payload.destinationY = layer.destinationY
        payload.destinationScale = layer.destinationScale
        step.component = .inputCameraDevice(payload)
      case .clock(var payload):
        payload.destinationX = layer.destinationX / coordinateWidth
        payload.destinationY = layer.destinationY / coordinateHeight
        payload.destinationWidth = layer.destinationScale
        payload.destinationHeight = layer.destinationScale
        step.component = .clock(payload)
      default:
        break
      }
      return step
    }
    return resolved
  }

  public static func applying(
    _ videoComponents: [WorkspaceVideoComponentRecord],
    to composite: CompositeProgramDefinition
  ) -> CompositeProgramDefinition {
    let componentsByName = firstVideoComponentsByName(videoComponents)
    var resolved = composite
    for index in resolved.steps.indices {
      let programComponent = resolved.steps[index].component
      guard var component = componentsByName[resolved.steps[index].name] else { continue }
      if case .inputCameraDevice(var resourcePayload) = component,
        case .inputCameraDevice(let programPayload) = programComponent
      {
        resourcePayload.destinationX = programPayload.destinationX
        resourcePayload.destinationY = programPayload.destinationY
        resourcePayload.destinationScale = programPayload.destinationScale
        component = .inputCameraDevice(resourcePayload)
      } else if case .clock(var resourcePayload) = component,
        case .clock(let programPayload) = programComponent
      {
        // Clock placement is resolved from Program Preferences into the
        // working composite. Keep it while refreshing Definition style.
        resourcePayload.destinationX = programPayload.destinationX
        resourcePayload.destinationY = programPayload.destinationY
        resourcePayload.destinationWidth = programPayload.destinationWidth
        resourcePayload.destinationHeight = programPayload.destinationHeight
        component = .clock(resourcePayload)
      }
      resolved.steps[index].component = component
    }
    return resolved
  }
}

private func firstProgramStepsByName(
  _ steps: [CompositeProgramStep]
) -> [String: CompositeProgramStep] {
  var stepsByName: [String: CompositeProgramStep] = [:]
  for step in steps where stepsByName[step.name] == nil {
    stepsByName[step.name] = step
  }
  return stepsByName
}

private func firstVideoComponentsByName(
  _ videoComponents: [WorkspaceVideoComponentRecord]
) -> [String: ProgramComponent] {
  var componentsByName: [String: ProgramComponent] = [:]
  for component in videoComponents where componentsByName[component.name] == nil {
    componentsByName[component.name] = component.component
  }
  return componentsByName
}

extension WorkspaceDefinition {
  @discardableResult
  public mutating func removeInputDevice(named name: String) -> Bool {
    guard inputDevices.contains(where: { $0.id == name }) else { return false }

    inputDevices.removeAll { $0.id == name }
    for programIndex in programs.indices {
      programs[programIndex].inputDevices.removeAll { $0.id == name }
      programs[programIndex].composite = programs[programIndex].composite
        .clearingInputDeviceReference(named: name)
    }
    audioChannels = audioChannels.map { $0.clearingInputDeviceReference(named: name) }
    videoComponents = videoComponents.map { $0.clearingInputDeviceReference(named: name) }
    if outputConfiguration.videoPTSMasterInputDeviceID == name {
      outputConfiguration.videoPTSMasterInputDeviceID = nil
    }
    for visionIndex in visions.indices {
      if case .inputDevice(let inputDeviceName) = visions[visionIndex].source,
        inputDeviceName == name
      {
        visions[visionIndex].source = .currentProgramOutput
      }
    }
    return true
  }

  @discardableResult
  public mutating func removeVision(named name: String) -> Bool {
    guard visions.contains(where: { $0.id == name }) else { return false }

    visions.removeAll { $0.id == name }
    return true
  }

  public mutating func renameInputDevice(
    from oldName: String,
    to newName: String,
    preferences: inout WorkspacePreferences
  ) throws {
    guard let index = inputDevices.firstIndex(where: { $0.name == oldName }) else {
      throw WorkspaceRenameError.resourceNotFound(oldName)
    }
    try validateRename(newName, excluding: oldName)

    var next = self
    var nextPreferences = preferences
    next.inputDevices[index].name = newName
    next.renameInputDeviceReferences(from: oldName, to: newName)
    if next.outputConfiguration.videoPTSMasterInputDeviceID == oldName {
      next.outputConfiguration.videoPTSMasterInputDeviceID = newName
    }
    nextPreferences.programPreferences.renameInputDevice(from: oldName, to: newName)
    if let physicalDeviceID = nextPreferences.physicalDeviceIDsByInputDeviceID.removeValue(
      forKey: oldName)
    {
      nextPreferences.physicalDeviceIDsByInputDeviceID[newName] = physicalDeviceID
    }
    self = next
    preferences = nextPreferences
  }

  public mutating func renameVision(from oldName: String, to newName: String) throws {
    guard let index = visions.firstIndex(where: { $0.name == oldName }) else {
      throw WorkspaceRenameError.resourceNotFound(oldName)
    }
    try validateRename(newName, excluding: oldName)

    visions[index].name = newName
  }

  public mutating func renameVideoComponent(
    from oldName: String,
    to newName: String,
    preferences: inout WorkspacePreferences
  ) throws {
    guard let index = videoComponents.firstIndex(where: { $0.name == oldName }) else {
      throw WorkspaceRenameError.resourceNotFound(oldName)
    }
    try validateRename(newName, excluding: oldName)

    videoComponents[index].name = newName
    for programIndex in programs.indices {
      for stepIndex in programs[programIndex].composite.steps.indices
      where programs[programIndex].composite.steps[stepIndex].name == oldName {
        programs[programIndex].composite.steps[stepIndex].name = newName
      }
    }
    preferences.programPreferences.renameVideoComponentReference(from: oldName, to: newName)
  }

  public mutating func renameProgram(
    from oldName: String,
    to newName: String,
    preferences: inout WorkspacePreferences
  ) throws {
    guard let index = programs.firstIndex(where: { $0.name == oldName }) else {
      throw WorkspaceRenameError.resourceNotFound(oldName)
    }
    guard !newName.isEmpty else { throw WorkspaceRenameError.emptyName }
    guard oldName == newName || !programs.contains(where: { $0.name == newName }) else {
      throw WorkspaceRenameError.duplicateName(newName)
    }

    programs[index].name = newName
    preferences.programPreferences.renameProgramReference(from: oldName, to: newName)
    if preferences.selectedProgramName == oldName {
      preferences.selectedProgramName = newName
    }
  }

  private mutating func renameInputDeviceReferences(from oldName: String, to newName: String) {
    for programIndex in programs.indices {
      for inputIndex in programs[programIndex].inputDevices.indices
      where programs[programIndex].inputDevices[inputIndex].name == oldName {
        programs[programIndex].inputDevices[inputIndex].name = newName
      }
      programs[programIndex].composite.renameInputDevice(from: oldName, to: newName)
    }
    for channelIndex in audioChannels.indices {
      if case .inputAudioDevice(var component) = audioChannels[channelIndex].component,
        component.inputDeviceID == oldName
      {
        component.inputDeviceID = newName
        audioChannels[channelIndex].component = .inputAudioDevice(component)
      }
    }
    for componentIndex in videoComponents.indices {
      guard case .inputCameraDevice(var component) = videoComponents[componentIndex].component,
        component.inputDeviceID == oldName
      else { continue }
      component.inputDeviceID = newName
      videoComponents[componentIndex].component = .inputCameraDevice(component)
    }
    for visionIndex in visions.indices {
      if case .inputDevice(let name) = visions[visionIndex].source, name == oldName {
        visions[visionIndex].source = .inputDevice(name: newName)
      }
    }
  }

  private func validateRename(_ newName: String, excluding oldName: String) throws {
    guard !newName.isEmpty else { throw WorkspaceRenameError.emptyName }
    guard
      WorkspaceResourceNameValidator.isAvailable(
        newName,
        inputDevices: inputDevices,
        videoComponents: videoComponents,
        visions: visions,
        excludingResourceID: oldName
      )
    else {
      throw WorkspaceRenameError.duplicateName(newName)
    }
  }
}

extension CompositeProgramDefinition {
  fileprivate func clearingInputDeviceReference(named name: String) -> Self {
    var updated = self
    for stepIndex in updated.steps.indices {
      guard case .inputCameraDevice(var payload) = updated.steps[stepIndex].component,
        payload.inputDeviceID == name
      else { continue }
      payload.inputDeviceID = nil
      updated.steps[stepIndex].component = .inputCameraDevice(payload)
    }
    return updated
  }
}

extension ProgramAudioChannel {
  fileprivate func clearingInputDeviceReference(named name: String) -> Self {
    guard case .inputAudioDevice(var payload) = component,
      payload.inputDeviceID == name
    else { return self }
    payload.inputDeviceID = nil
    return ProgramAudioChannel(id: id, component: .inputAudioDevice(payload))
  }
}

extension WorkspaceVideoComponentRecord {
  fileprivate func clearingInputDeviceReference(named name: String) -> Self {
    var updated = self
    guard updated.inputDeviceID == name else { return updated }
    updated.inputDeviceID = nil
    return updated
  }
}

public enum WorkspaceRenameError: Error, Equatable, LocalizedError {
  case emptyName
  case duplicateName(String)
  case resourceNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .emptyName:
      "Name cannot be empty."
    case .duplicateName(let name):
      "A Workspace resource named '\(name)' already exists."
    case .resourceNotFound(let name):
      "Workspace resource '\(name)' was not found."
    }
  }
}

public typealias WorkspaceInputDeviceRecord = ProgramInputDeviceRecord
public typealias WorkspaceInputDeviceKind = ProgramInputDeviceKind
public typealias WorkspaceInputDeviceBackgroundRemovalPolicy =
  ProgramInputDeviceBackgroundRemovalPolicy
public typealias WorkspaceInputDeviceColorRangePolicy = ProgramInputDeviceColorRangePolicy
