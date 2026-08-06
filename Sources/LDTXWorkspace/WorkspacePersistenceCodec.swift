// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import OSLog
import SwiftProtobuf

private let workspacePersistenceLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "workspace-persistence"
)

public enum WorkspacePersistenceCodec {
  public static func encodeWorkspace(_ workspace: WorkspaceDefinition) throws -> Data {
    try workspace.protoMessage.serializedData()
  }

  public static func decodeWorkspace(
    from data: Data,
    preferences: WorkspacePreferences = WorkspacePreferences()
  ) throws -> WorkspaceSnapshot {
    let persisted = try Ldtx_Workspace_V1_Workspace(serializedBytes: data)
    let protobufMigration = try WorkspaceMigrator.migrate(persisted)
    let definition = try protobufMigration.workspace.decodedDomainModel
    let snapshot = WorkspaceMigrator.migrate(
      definition: definition,
      preferences: preferences,
      protobufMigration: protobufMigration
    )
    try WorkspaceIntegrityValidator.validateForLoading(
      snapshot.definition,
      preferences: snapshot.preferences
    )
    return snapshot
  }

  public static func encodeWorkspaceJSON(_ workspace: WorkspaceDefinition) throws -> Data {
    try workspace.protoMessage.jsonUTF8Data()
  }

  public static func decodeWorkspaceJSON(
    from data: Data,
    preferences: WorkspacePreferences = WorkspacePreferences()
  ) throws -> WorkspaceSnapshot {
    let persisted = try Ldtx_Workspace_V1_Workspace(jsonUTF8Data: data)
    let protobufMigration = try WorkspaceMigrator.migrate(persisted)
    let definition = try protobufMigration.workspace.decodedDomainModel
    let snapshot = WorkspaceMigrator.migrate(
      definition: definition,
      preferences: preferences,
      protobufMigration: protobufMigration
    )
    try WorkspaceIntegrityValidator.validateForLoading(
      snapshot.definition,
      preferences: snapshot.preferences
    )
    return snapshot
  }

  public static func encodePreferences(_ preferences: WorkspacePreferences) throws -> Data {
    try preferences.protoMessage.serializedData()
  }

  public static func decodePreferences(from data: Data) throws -> WorkspacePreferences {
    try Ldtx_Workspace_V1_WorkspacePreferences(serializedBytes: data).domainModel
  }

  public static func encodePreferencesJSON(_ preferences: WorkspacePreferences) throws -> Data {
    try preferences.protoMessage.jsonUTF8Data()
  }

}

/// The complete semantic state loaded from one Workspace bundle.
///
/// Definition and Preferences are intentionally kept together because
/// references and migrated values are only meaningful as a consistent pair.
public struct WorkspaceSnapshot: Equatable, Sendable {
  public var definition: WorkspaceDefinition
  public var preferences: WorkspacePreferences

  public init(definition: WorkspaceDefinition, preferences: WorkspacePreferences) {
    self.definition = definition
    self.preferences = preferences
  }
}

private enum WorkspacePersistenceCodecError: Error {
  case missingProgramRecord
  case missingProgramPreferencesRecord
  case unsigned32OutOfRange(String, Int)
}

extension WorkspaceDefinition {
  fileprivate var protoMessage: Ldtx_Workspace_V1_Workspace {
    get throws {
      var proto = Ldtx_Workspace_V1_Workspace()
      proto.formatVersion = WorkspaceMigrator.currentFormatVersion
      proto.lineageID = lineageID.uuidString.lowercased()
      proto.name = name
      proto.programs = try programs.map { try $0.workspaceProtoMessage }
      proto.inputDevices = try inputDevices.map { try $0.protoMessage() }
      proto.audioChannels = audioChannels.map(\.workspaceProtoMessage)
      proto.visions = visions.map(\.workspaceProtoMessage)
      proto.videoComponents = videoComponents.map(\.workspaceProtoMessage)
      proto.outputConfiguration = outputConfiguration.workspaceProtoMessage
      return proto
    }
  }
}

extension Ldtx_Workspace_V1_Workspace {
  fileprivate var decodedDomainModel: WorkspaceDefinition {
    get throws {
      let decodedInputDevices = inputDevices.map(\.domainModel)
      let decodedPrograms = try programs.map { try $0.domainModel }
      let decodedAudioChannels = audioChannels.map(\.domainModel)
      let decodedVisions = visions.map(\.domainModel)
      let decodedVideoComponents = videoComponents.map(\.domainModel)
      let workspace = WorkspaceDefinition(
        lineageID: UUID(uuidString: lineageID) ?? UUID(),
        name: name,
        programs: decodedPrograms,
        inputDevices: decodedInputDevices,
        audioChannels: decodedAudioChannels,
        visions: decodedVisions,
        videoComponents: decodedVideoComponents,
        outputConfiguration: outputConfiguration.domainModel ?? WorkspaceOutputConfiguration()
      )
      try WorkspaceIntegrityValidator.validateForLoading(workspace)
      return workspace
    }
  }
}

extension WorkspaceOutputConfiguration {
  fileprivate var workspaceProtoMessage: Ldtx_Workspace_V1_WorkspaceOutputConfiguration {
    var proto = Ldtx_Workspace_V1_WorkspaceOutputConfiguration()
    proto.canvasWidth = UInt32(clamping: canvasWidth)
    proto.canvasHeight = UInt32(clamping: canvasHeight)
    proto.frameRate = UInt32(clamping: frameRate)
    proto.profileID = profileID?.rawValue ?? ""
    proto.videoBitRate = UInt32(clamping: videoBitRate)
    if let videoPTSMasterInputDeviceID {
      proto.videoPtsMasterInputDeviceID = videoPTSMasterInputDeviceID
    }
    return proto
  }
}

extension Ldtx_Workspace_V1_WorkspaceOutputConfiguration {
  fileprivate var domainModel: WorkspaceOutputConfiguration? {
    guard canvasWidth > 0, canvasHeight > 0, frameRate > 0 else { return nil }
    return WorkspaceOutputConfiguration(
      profileID: WorkspaceOutputProfileID(rawValue: profileID),
      canvasWidth: Int(canvasWidth),
      canvasHeight: Int(canvasHeight),
      frameRate: Int(frameRate),
      videoBitRate: videoBitRate > 0 ? Int(videoBitRate) : 6_000_000,
      videoPTSMasterInputDeviceID: videoPtsMasterInputDeviceID.nilIfEmpty
    )
  }
}

extension WorkspaceVideoComponentRecord {
  fileprivate var workspaceProtoMessage: Ldtx_Workspace_V1_VideoComponentRecord {
    var proto = Ldtx_Workspace_V1_VideoComponentRecord()
    proto.name = name
    proto.component = ProgramPersistenceCodec.encodeProgramComponent(component)
    return proto
  }
}

extension Ldtx_Workspace_V1_VideoComponentRecord {
  fileprivate var domainModel: WorkspaceVideoComponentRecord {
    return WorkspaceVideoComponentRecord(
      name: name,
      component: ProgramPersistenceCodec.decodeProgramComponent(component)
    )
  }
}

extension WorkspaceVisionDefinition {
  fileprivate var workspaceProtoMessage: Ldtx_Workspace_V1_VisionRecord {
    var proto = Ldtx_Workspace_V1_VisionRecord()
    proto.name = name
    switch source {
    case .currentProgramOutput:
      proto.currentProgramOutput = true
    case .inputDevice(let name):
      proto.inputDeviceName = name
    }
    proto.sourceCrop.top = sourceCrop.top
    proto.sourceCrop.right = sourceCrop.right
    proto.sourceCrop.bottom = sourceCrop.bottom
    proto.sourceCrop.left = sourceCrop.left
    proto.updateIntervalSeconds = updateIntervalSeconds ?? 0
    if let histogramGate {
      let histogramGate = WorkspaceVisionHistogramGate(
        channel: histogramGate.channel,
        binCount: histogramGate.binCount,
        expectedPeakBin: histogramGate.expectedPeakBin,
        minimumPeakRatio: histogramGate.minimumPeakRatio,
        region: histogramGate.region
      )
      var gate = Ldtx_Workspace_V1_VisionHistogramGate()
      switch histogramGate.channel {
      case .hue: gate.channel = .hue
      case .saturation: gate.channel = .saturation
      case .value: gate.channel = .value
      }
      gate.binCount = UInt32(histogramGate.binCount)
      gate.expectedPeakBin = UInt32(histogramGate.expectedPeakBin)
      gate.minimumPeakRatio = histogramGate.minimumPeakRatio
      gate.region.x = histogramGate.region.x
      gate.region.y = histogramGate.region.y
      gate.region.width = histogramGate.region.width
      gate.region.height = histogramGate.region.height
      proto.histogramGate = gate
    }
    switch definition {
    case .visionLanguageModel(let value):
      var definition = Ldtx_Workspace_V1_VisionLanguageModelDefinition()
      definition.modelRepositoryID = value.model.repositoryID
      if let revision = value.model.revision { definition.modelRevision = revision }
      definition.expectedWeightSha256 = value.model.expectedWeightSHA256
      definition.systemPrompt = value.systemPrompt
      definition.userPrompt = value.userPrompt
      definition.stopsAtNewline = value.stopsAtNewline
      proto.visionLanguageModel = definition
    case .opticalCharacterRecognition(let value):
      var definition = Ldtx_Workspace_V1_VisionOCRDefinition()
      switch value.recognitionLevel {
      case .fast: definition.recognitionLevel = .fast
      case .accurate: definition.recognitionLevel = .accurate
      }
      definition.recognitionLanguages = value.recognitionLanguages
      definition.usesLanguageCorrection = value.usesLanguageCorrection
      definition.subsamplingRate = UInt32(value.subsamplingRate)
      proto.opticalCharacterRecognition = definition
    }
    return proto
  }
}

extension Ldtx_Workspace_V1_VisionRecord {
  fileprivate var domainModel: WorkspaceVisionDefinition {
    let source: WorkspaceVisionSource
    switch self.source {
    case .inputDeviceName(let id):
      source = .inputDevice(name: id)
    case .currentProgramOutput, nil:
      source = .currentProgramOutput
    }
    let definition: WorkspaceVisionKind
    switch self.definition {
    case .opticalCharacterRecognition(let value):
      let recognitionLevel: WorkspaceVisionOCRDefinition.RecognitionLevel
      switch value.recognitionLevel {
      case .fast: recognitionLevel = .fast
      case .accurate, .unspecified, .UNRECOGNIZED: recognitionLevel = .accurate
      }
      definition = .opticalCharacterRecognition(
        .init(
          recognitionLevel: recognitionLevel,
          recognitionLanguages: value.recognitionLanguages,
          usesLanguageCorrection: value.hasUsesLanguageCorrection
            ? value.usesLanguageCorrection : true,
          subsamplingRate: [1, 2, 4].contains(Int(value.subsamplingRate))
            ? Int(value.subsamplingRate) : 2
        ))
    case .visionLanguageModel(let value):
      let repositoryID =
        value.modelRepositoryID.isEmpty
        ? WorkspaceVisionModel.qwen3VL2BInstruct4Bit.repositoryID
        : value.modelRepositoryID
      let model =
        value.expectedWeightSha256.isEmpty
        ? WorkspaceVisionModel.builtInModel(repositoryID: repositoryID)
          ?? WorkspaceVisionModel(
            repositoryID: repositoryID,
            revision: value.hasModelRevision ? value.modelRevision : nil)
        : WorkspaceVisionModel(
          repositoryID: repositoryID,
          revision: value.hasModelRevision ? value.modelRevision : nil,
          expectedWeightSHA256: value.expectedWeightSha256)
      definition = .visionLanguageModel(
        .init(
          model: model,
          systemPrompt: value.systemPrompt.isEmpty
            ? WorkspaceVisionDefinition.defaultSystemPrompt : value.systemPrompt,
          userPrompt: value.userPrompt.isEmpty
            ? WorkspaceVisionDefinition.defaultUserPrompt : value.userPrompt,
          stopsAtNewline: value.stopsAtNewline
        ))
    case nil:
      definition = .visionLanguageModel(.init())
    }
    var result = WorkspaceVisionDefinition(
      name: name.isEmpty ? "Vision" : name,
      source: source,
      sourceCrop: .init(
        top: sourceCrop.top, right: sourceCrop.right,
        bottom: sourceCrop.bottom, left: sourceCrop.left
      ),
      updateIntervalSeconds: updateIntervalSeconds > 0 ? updateIntervalSeconds : nil,
      histogramGate: hasHistogramGate ? histogramGate.domainModel : nil
    )
    result.definition = definition
    return result
  }
}

extension Ldtx_Workspace_V1_VisionHistogramGate {
  fileprivate var domainModel: WorkspaceVisionHistogramGate {
    let defaults = WorkspaceVisionHistogramGate()
    let domainChannel: WorkspaceVisionHistogramGate.Channel
    switch channel {
    case .hue: domainChannel = .hue
    case .saturation: domainChannel = .saturation
    case .value, .unspecified, .UNRECOGNIZED: domainChannel = .value
    }
    return .init(
      channel: domainChannel,
      binCount: hasBinCount ? Int(binCount) : defaults.binCount,
      expectedPeakBin: hasExpectedPeakBin ? Int(expectedPeakBin) : defaults.expectedPeakBin,
      minimumPeakRatio: hasMinimumPeakRatio
        ? minimumPeakRatio : defaults.minimumPeakRatio,
      region: hasRegion
        ? .init(x: region.x, y: region.y, width: region.width, height: region.height)
        : .init()
    )
  }
}

extension SavedProgramDefinitionRecord {
  fileprivate var workspaceProtoMessage: Ldtx_Workspace_V1_ProgramRecord {
    get throws {
      let data = try ProgramPersistenceCodec.encodeProgramDefinitions([self])
      let library = try Ldtx_Program_Persistence_V1_SavedProgramDefinitionLibrary(
        serializedBytes: data)
      guard let record = library.records.first else {
        throw WorkspacePersistenceCodecError.missingProgramRecord
      }

      var proto = Ldtx_Workspace_V1_ProgramRecord()
      proto.name = record.name
      proto.canvasWidth = record.canvasWidth
      proto.canvasHeight = record.canvasHeight
      proto.frameRateNumerator = record.frameRateNumerator
      proto.frameRateDenominator = record.frameRateDenominator
      proto.program = record.program
      return proto
    }
  }
}

extension Ldtx_Workspace_V1_ProgramRecord {
  fileprivate var domainModel: SavedProgramDefinitionRecord {
    get throws {
      var record = Ldtx_Program_Persistence_V1_SavedProgramDefinitionRecord()
      record.name = name
      record.canvasWidth = canvasWidth
      record.canvasHeight = canvasHeight
      record.frameRateNumerator = frameRateNumerator
      record.frameRateDenominator = frameRateDenominator
      record.program = program

      var library = Ldtx_Program_Persistence_V1_SavedProgramDefinitionLibrary()
      library.records = [record]
      let data = try library.serializedData()
      guard let decoded = try ProgramPersistenceCodec.decodeProgramDefinitions(from: data).first
      else {
        throw WorkspacePersistenceCodecError.missingProgramRecord
      }
      return decoded
    }
  }
}

extension WorkspacePreferences {
  fileprivate var protoMessage: Ldtx_Workspace_V1_WorkspacePreferences {
    get throws {
      var proto = Ldtx_Workspace_V1_WorkspacePreferences()
      proto.program = try Ldtx_Program_Persistence_V1_ProgramPreferences(
        serializedBytes: ProgramPersistenceCodec.encodeProgramPreferences(programPreferences)
      )
      proto.physicalDeviceIdsByInputDeviceID = physicalDeviceIDsByInputDeviceID
      proto.inputCameraDeviceMappings = inputCameraDeviceMappings
      proto.inputAudioDeviceMappings = inputAudioDeviceMappings
      proto.inputAudioMonitorChannelKeys = inputAudioMonitorChannelKeys.sorted()
      if let selectedProgramName { proto.selectedProgramName = selectedProgramName }
      proto.outputDestination = outputDestination.protoMessage
      return proto
    }
  }
}

extension Ldtx_Workspace_V1_WorkspacePreferences {
  fileprivate var domainModel: WorkspacePreferences {
    get throws {
      WorkspacePreferences(
        programPreferences: try ProgramPersistenceCodec.decodeProgramPreferences(
          from: program.serializedData()
        ),
        physicalDeviceIDsByInputDeviceID: physicalDeviceIdsByInputDeviceID,
        inputCameraDeviceMappings: inputCameraDeviceMappings,
        inputAudioDeviceMappings: inputAudioDeviceMappings,
        inputAudioMonitorChannelKeys: Set(inputAudioMonitorChannelKeys),
        selectedProgramName: hasSelectedProgramName ? selectedProgramName : nil,
        // New Workspaces always persist this message. Absence is treated only
        // as malformed or legacy input; no historical output selection is inferred.
        outputDestination: hasOutputDestination
          ? outputDestination.domainModel : .missingPersistedValueFallback
      )
    }
  }
}

extension WorkspaceInputDeviceRecord {
  fileprivate func protoMessage() throws -> Ldtx_Workspace_V1_InputDeviceRecord {
    var proto = Ldtx_Workspace_V1_InputDeviceRecord()
    proto.name = name
    proto.kind = kind.protoValue
    proto.backgroundRemovalPolicy = backgroundRemovalPolicy.protoValue
    proto.colorRangePolicy = colorRangePolicy.protoValue
    if let captureWidthOverride {
      proto.captureWidthOverride = try uint32(captureWidthOverride, field: "captureWidthOverride")
    }
    if let captureHeightOverride {
      proto.captureHeightOverride = try uint32(
        captureHeightOverride, field: "captureHeightOverride")
    }
    if let captureFrameRateOverride {
      proto.captureFrameRateOverride = try uint32(
        captureFrameRateOverride,
        field: "captureFrameRateOverride"
      )
    }
    return proto
  }

  private func uint32(_ value: Int, field: String) throws -> UInt32 {
    guard let converted = UInt32(exactly: value) else {
      throw WorkspacePersistenceCodecError.unsigned32OutOfRange(field, value)
    }
    return converted
  }
}

extension ProgramAudioChannel {
  fileprivate var workspaceProtoMessage: Ldtx_Program_V1_ProgramAudioChannel {
    var proto = Ldtx_Program_V1_ProgramAudioChannel()
    proto.name = name
    switch component {
    case .inputAudioDevice(let payload):
      proto.inputAudioDevice = payload.workspaceProtoMessage
    case .silentAudio:
      proto.silentAudio = Ldtx_Program_V1_SilentAudioComponent()
    case .testPatternAudio:
      proto.testPatternAudio = Ldtx_Program_V1_TestPatternAudioComponent()
    }
    return proto
  }
}

extension Ldtx_Program_V1_ProgramAudioChannel {
  fileprivate var domainModel: ProgramAudioChannel {
    let component: ProgramAudioChannelComponent
    switch definition {
    case .inputAudioDevice(let payload):
      component = .inputAudioDevice(payload.domainModel)
    case .silentAudio:
      component = .silentAudio
    case .testPatternAudio:
      component = .testPatternAudio
    case nil:
      component = .inputAudioDevice(InputAudioDeviceComponent())
    }
    return ProgramAudioChannel(name: name, component: component)
  }
}

extension InputAudioDeviceComponent {
  fileprivate var workspaceProtoMessage: Ldtx_Program_V1_InputAudioDeviceComponent {
    var proto = Ldtx_Program_V1_InputAudioDeviceComponent()
    if let inputDeviceID {
      proto.inputDeviceID = inputDeviceID
    }
    return proto
  }
}

extension Ldtx_Program_V1_InputAudioDeviceComponent {
  fileprivate var domainModel: InputAudioDeviceComponent {
    InputAudioDeviceComponent(inputDeviceID: inputDeviceID.nilIfEmpty)
  }
}

extension Ldtx_Workspace_V1_InputDeviceRecord {
  fileprivate var domainModel: WorkspaceInputDeviceRecord {
    WorkspaceInputDeviceRecord(
      name: name,
      kind: kind.domainModel,
      physicalDeviceID: nil,
      backgroundRemovalPolicy: backgroundRemovalPolicy.domainModel,
      colorRangePolicy: colorRangePolicy.domainModel,
      captureWidthOverride: captureWidthOverride.nilIfZero,
      captureHeightOverride: captureHeightOverride.nilIfZero,
      captureFrameRateOverride: captureFrameRateOverride.nilIfZero
    )
  }
}

extension UInt32 {
  fileprivate var nilIfZero: Int? {
    self == 0 ? nil : Int(self)
  }
}

extension WorkspaceInputDeviceKind {
  fileprivate var protoValue: Ldtx_Workspace_V1_InputDeviceKind {
    switch self {
    case .unspecified:
      .unspecified
    case .video:
      .video
    case .audio:
      .audio
    }
  }
}

extension Ldtx_Workspace_V1_InputDeviceKind {
  fileprivate var domainModel: WorkspaceInputDeviceKind {
    switch self {
    case .unspecified, .UNRECOGNIZED(_):
      .unspecified
    case .video:
      .video
    case .audio:
      .audio
    }
  }
}

extension WorkspaceInputDeviceBackgroundRemovalPolicy {
  fileprivate var protoValue: Ldtx_Workspace_V1_BackgroundRemovalPolicy {
    switch self {
    case .unspecified:
      .unspecified
    case .enabled:
      .enabled
    case .disabled:
      .disabled
    }
  }
}

extension Ldtx_Workspace_V1_BackgroundRemovalPolicy {
  fileprivate var domainModel: WorkspaceInputDeviceBackgroundRemovalPolicy {
    switch self {
    case .unspecified, .UNRECOGNIZED(_):
      .unspecified
    case .enabled:
      .enabled
    case .disabled:
      .disabled
    }
  }
}

extension WorkspaceInputDeviceColorRangePolicy {
  fileprivate var protoValue: Ldtx_Workspace_V1_ColorRangePolicy {
    switch self {
    case .unspecified:
      .unspecified
    case .videoRange:
      .videoRange
    case .fullRange:
      .fullRange
    }
  }
}

extension Ldtx_Workspace_V1_ColorRangePolicy {
  fileprivate var domainModel: WorkspaceInputDeviceColorRangePolicy {
    switch self {
    case .unspecified, .UNRECOGNIZED(_):
      .unspecified
    case .videoRange:
      .videoRange
    case .fullRange:
      .fullRange
    }
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
