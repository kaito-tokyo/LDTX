// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import OSLog
import SwiftProtobuf

private let programPersistenceLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "program-persistence"
)

public enum ProgramPersistenceCodec {
  public static func encodeProgram(
    _ definition: CompositeProgramDefinition
  ) -> Ldtx_Program_V1_Program {
    definition.protoMessage
  }

  public static func decodeProgram(
    _ program: Ldtx_Program_V1_Program
  ) -> CompositeProgramDefinition {
    normalizedProgramComposite(program.domainModel, programName: "Standalone Program")
  }

  public static func encodeProgramComponent(_ component: ProgramComponent)
    -> Ldtx_Program_V1_ProgramComponent
  {
    CompositeProgramStep(component: component).protoMessage
  }

  public static func decodeProgramComponent(_ component: Ldtx_Program_V1_ProgramComponent)
    -> ProgramComponent
  {
    component.domainModel.component
  }

  public static func encodeProgramDefinitions(_ records: [SavedProgramDefinitionRecord]) throws
    -> Data
  {
    var library = Ldtx_Program_Persistence_V1_SavedProgramDefinitionLibrary()
    library.records = try records.map { try $0.protoMessage() }
    return try library.serializedData()
  }

  public static func decodeProgramDefinitions(from data: Data) throws
    -> [SavedProgramDefinitionRecord]
  {
    let library = try Ldtx_Program_Persistence_V1_SavedProgramDefinitionLibrary(
      serializedBytes: data)
    return library.records.map { record in
      var definition = record.domainModel
      definition.composite = normalizedProgramComposite(
        definition.composite,
        programName: definition.name
      )
      return definition
    }
  }

  public static func encodeProgramPreferences(_ preferences: ProgramPreferences) throws -> Data {
    try preferences.protoMessage.serializedData()
  }

  public static func decodeProgramPreferences(from data: Data) throws -> ProgramPreferences {
    try Ldtx_Program_Persistence_V1_ProgramPreferences(serializedBytes: data).domainModel
  }
}

private func normalizedProgramComposite(
  _ composite: CompositeProgramDefinition,
  programName: String
) -> CompositeProgramDefinition {
  var seenStepNames = Set<String>()
  var discardedStepNames: [String] = []
  var normalized = composite
  normalized.steps = composite.steps.filter { step in
    guard seenStepNames.insert(step.name).inserted else {
      discardedStepNames.append(step.name)
      return false
    }
    return true
  }
  if !discardedStepNames.isEmpty {
    programPersistenceLogger.warning(
      "Discarded duplicate Program Steps during load program=\(programName, privacy: .public) discardedStepNames=\(discardedStepNames.joined(separator: ","), privacy: .public) discardedCount=\(discardedStepNames.count, privacy: .public)"
    )
  }
  return normalized
}

private enum ProgramPersistenceCodecError: Error {
  case unsigned32OutOfRange(String, Int)
}

extension SavedProgramDefinitionRecord {
  fileprivate func protoMessage() throws -> Ldtx_Program_Persistence_V1_SavedProgramDefinitionRecord
  {
    var proto = Ldtx_Program_Persistence_V1_SavedProgramDefinitionRecord()
    proto.name = name
    proto.canvasWidth = try uint32(canvasWidth, field: "canvasWidth")
    proto.canvasHeight = try uint32(canvasHeight, field: "canvasHeight")
    proto.frameRateNumerator = try uint32(frameRateNumerator, field: "frameRateNumerator")
    proto.frameRateDenominator = try uint32(frameRateDenominator, field: "frameRateDenominator")
    proto.program = composite.protoMessage
    proto.inputDevices = try inputDevices.map { try $0.protoMessage() }
    return proto
  }

  private func uint32(_ value: Int, field: String) throws -> UInt32 {
    guard let converted = UInt32(exactly: value) else {
      throw ProgramPersistenceCodecError.unsigned32OutOfRange(field, value)
    }
    return converted
  }
}

extension Ldtx_Program_Persistence_V1_SavedProgramDefinitionRecord {
  fileprivate var domainModel: SavedProgramDefinitionRecord {
    SavedProgramDefinitionRecord(
      name: name,
      canvasWidth: Int(canvasWidth),
      canvasHeight: Int(canvasHeight),
      frameRateNumerator: Int(frameRateNumerator),
      frameRateDenominator: Int(frameRateDenominator),
      composite: program.domainModel,
      inputDevices: inputDevices.map(\.domainModel)
    )
  }
}

extension ProgramPreferences {
  fileprivate var protoMessage: Ldtx_Program_Persistence_V1_ProgramPreferences {
    var proto = Ldtx_Program_Persistence_V1_ProgramPreferences()
    proto.audioChannelGainsByName = audioChannelGainsByName
    proto.videoMutedByInputDeviceName = videoMutedByInputDeviceName
    proto.audioMutedByInputDeviceName = audioMutedByInputDeviceName
    proto.videoLayersByProgramName = videoLayersByProgramName.mapValues { layers in
      var list = Ldtx_Program_Persistence_V1_VideoLayerPreferences()
      list.layers = layers.map { layer in
        var protoLayer = Ldtx_Program_Persistence_V1_VideoLayerPreference()
        protoLayer.componentName = layer.componentName
        protoLayer.destination = .destination(
          x: layer.destinationX,
          y: layer.destinationY,
          scale: layer.destinationScale
        )
        protoLayer.muted = layer.isMuted
        return protoLayer
      }
      return list
    }
    return proto
  }
}

extension ProgramInputDeviceRecord {
  fileprivate func protoMessage() throws -> Ldtx_Program_Persistence_V1_InputDeviceRecord {
    var proto = Ldtx_Program_Persistence_V1_InputDeviceRecord()
    proto.name = name
    proto.kind = kind.protoValue
    if let physicalDeviceID {
      proto.physicalDeviceID = physicalDeviceID
    }
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
      throw ProgramPersistenceCodecError.unsigned32OutOfRange(field, value)
    }
    return converted
  }
}

extension Ldtx_Program_Persistence_V1_InputDeviceRecord {
  fileprivate var domainModel: ProgramInputDeviceRecord {
    ProgramInputDeviceRecord(
      name: name,
      kind: kind.domainModel,
      physicalDeviceID: physicalDeviceID.nilIfEmpty,
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

extension ProgramInputDeviceKind {
  fileprivate var protoValue: Ldtx_Program_Persistence_V1_InputDeviceKind {
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

extension Ldtx_Program_Persistence_V1_InputDeviceKind {
  fileprivate var domainModel: ProgramInputDeviceKind {
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

extension ProgramInputDeviceBackgroundRemovalPolicy {
  fileprivate var protoValue: Ldtx_Program_Persistence_V1_BackgroundRemovalPolicy {
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

extension Ldtx_Program_Persistence_V1_BackgroundRemovalPolicy {
  fileprivate var domainModel: ProgramInputDeviceBackgroundRemovalPolicy {
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

extension ProgramInputDeviceColorRangePolicy {
  fileprivate var protoValue: Ldtx_Program_Persistence_V1_ColorRangePolicy {
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

extension Ldtx_Program_Persistence_V1_ColorRangePolicy {
  fileprivate var domainModel: ProgramInputDeviceColorRangePolicy {
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

extension Ldtx_Program_Persistence_V1_ProgramPreferences {
  fileprivate var domainModel: ProgramPreferences {
    ProgramPreferences(
      audioChannelGainsByName: audioChannelGainsByName,
      videoMutedByInputDeviceName: videoMutedByInputDeviceName,
      audioMutedByInputDeviceName: audioMutedByInputDeviceName,
      videoLayersByProgramName: videoLayersByProgramName.mapValues { list in
        list.layers.map {
          VideoLayerPreference(
            componentName: $0.componentName,
            destinationX: $0.destination.x,
            destinationY: $0.destination.y,
            destinationScale: $0.destination.scale,
            isMuted: $0.muted
          )
        }
      }
    )
  }
}

extension CompositeProgramDefinition {
  fileprivate var protoMessage: Ldtx_Program_V1_Program {
    var proto = Ldtx_Program_V1_Program()
    proto.components = steps.map(\.protoMessage)
    proto.audioChannels = audioChannels.map(\.protoMessage)
    return proto
  }
}

extension Ldtx_Program_V1_Program {
  fileprivate var domainModel: CompositeProgramDefinition {
    CompositeProgramDefinition(
      steps: components.map(\.domainModel),
      audioChannels: audioChannels.map(\.domainModel)
    )
  }
}

extension CompositeProgramStep {
  fileprivate var protoMessage: Ldtx_Program_V1_ProgramComponent {
    var proto = Ldtx_Program_V1_ProgramComponent()
    proto.name = name
    switch component {
    case .fillSolidColor(let payload):
      proto.solidColorFill = payload.protoMessage
    case .fillLinearGradient(let payload):
      proto.linearGradientFill = payload.protoMessage
    case .fillRadialGradient(let payload):
      proto.radialGradientFill = payload.protoMessage
    case .fillConicGradient(let payload):
      proto.conicGradientFill = payload.protoMessage
    case .inputCameraDevice(let payload):
      proto.inputDevice = payload.protoMessage
    case .clock(let payload):
      proto.clock = payload.protoMessage
    case .testPattern:
      proto.testPattern = Ldtx_Program_V1_TestPatternComponent()
    }
    return proto
  }
}

extension Ldtx_Program_V1_ProgramComponent {
  fileprivate var domainModel: CompositeProgramStep {
    let component: ProgramComponent
    switch definition {
    case .solidColorFill(let payload):
      component = .fillSolidColor(payload.domainModel)
    case .linearGradientFill(let payload):
      component = .fillLinearGradient(payload.domainModel)
    case .radialGradientFill(let payload):
      component = .fillRadialGradient(payload.domainModel)
    case .conicGradientFill(let payload):
      component = .fillConicGradient(payload.domainModel)
    case .inputDevice(let payload):
      component = .inputCameraDevice(payload.domainModel)
    case .clock(let payload):
      component = .clock(payload.domainModel)
    case .testPattern:
      component = .testPattern
    case nil:
      component = .inputCameraDevice(InputDeviceComponent())
    }
    return CompositeProgramStep(
      displayName: name,
      component: component
    )
  }
}

extension ProgramAudioChannel {
  fileprivate var protoMessage: Ldtx_Program_V1_ProgramAudioChannel {
    var proto = Ldtx_Program_V1_ProgramAudioChannel()
    proto.name = name
    switch component {
    case .inputAudioDevice(let payload):
      proto.inputAudioDevice = payload.protoMessage
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

extension FillSolidColorComponent {
  fileprivate var protoMessage: Ldtx_Program_V1_FillSolidColorComponent {
    var proto = Ldtx_Program_V1_FillSolidColorComponent()
    proto.color = .color(red: red, green: green, blue: blue, alpha: alpha)
    proto.clip = clip.protoMessage
    return proto
  }
}

extension Ldtx_Program_V1_FillSolidColorComponent {
  fileprivate var domainModel: FillSolidColorComponent {
    FillSolidColorComponent(
      red: color.red,
      green: color.green,
      blue: color.blue,
      alpha: color.alpha,
      clip: clip.domainModel
    )
  }
}

extension FillLinearGradientComponent {
  fileprivate var protoMessage: Ldtx_Program_V1_FillLinearGradientComponent {
    var proto = Ldtx_Program_V1_FillLinearGradientComponent()
    proto.start = .point(x: startX, y: startY)
    proto.end = .point(x: endX, y: endY)
    proto.startColor = .color(red: startRed, green: startGreen, blue: startBlue, alpha: startAlpha)
    proto.endColor = .color(red: endRed, green: endGreen, blue: endBlue, alpha: endAlpha)
    proto.clip = clip.protoMessage
    return proto
  }
}

extension Ldtx_Program_V1_FillLinearGradientComponent {
  fileprivate var domainModel: FillLinearGradientComponent {
    FillLinearGradientComponent(
      startX: start.x,
      startY: start.y,
      endX: end.x,
      endY: end.y,
      startRed: startColor.red,
      startGreen: startColor.green,
      startBlue: startColor.blue,
      startAlpha: startColor.alpha,
      endRed: endColor.red,
      endGreen: endColor.green,
      endBlue: endColor.blue,
      endAlpha: endColor.alpha,
      clip: clip.domainModel
    )
  }
}

extension FillRadialGradientComponent {
  fileprivate var protoMessage: Ldtx_Program_V1_FillRadialGradientComponent {
    var proto = Ldtx_Program_V1_FillRadialGradientComponent()
    proto.center = .point(x: centerX, y: centerY)
    proto.innerRadius = innerRadius
    proto.outerRadius = outerRadius
    proto.innerColor = .color(red: innerRed, green: innerGreen, blue: innerBlue, alpha: innerAlpha)
    proto.outerColor = .color(red: outerRed, green: outerGreen, blue: outerBlue, alpha: outerAlpha)
    proto.clip = clip.protoMessage
    return proto
  }
}

extension Ldtx_Program_V1_FillRadialGradientComponent {
  fileprivate var domainModel: FillRadialGradientComponent {
    FillRadialGradientComponent(
      centerX: center.x,
      centerY: center.y,
      innerRadius: innerRadius,
      outerRadius: outerRadius,
      innerRed: innerColor.red,
      innerGreen: innerColor.green,
      innerBlue: innerColor.blue,
      innerAlpha: innerColor.alpha,
      outerRed: outerColor.red,
      outerGreen: outerColor.green,
      outerBlue: outerColor.blue,
      outerAlpha: outerColor.alpha,
      clip: clip.domainModel
    )
  }
}

extension FillConicGradientComponent {
  fileprivate var protoMessage: Ldtx_Program_V1_FillConicGradientComponent {
    var proto = Ldtx_Program_V1_FillConicGradientComponent()
    proto.center = .point(x: centerX, y: centerY)
    proto.startAngleRadians = startAngleRadians
    proto.startColor = .color(red: startRed, green: startGreen, blue: startBlue, alpha: startAlpha)
    proto.endColor = .color(red: endRed, green: endGreen, blue: endBlue, alpha: endAlpha)
    proto.clip = clip.protoMessage
    return proto
  }
}

extension Ldtx_Program_V1_FillConicGradientComponent {
  fileprivate var domainModel: FillConicGradientComponent {
    FillConicGradientComponent(
      centerX: center.x,
      centerY: center.y,
      startAngleRadians: startAngleRadians,
      startRed: startColor.red,
      startGreen: startColor.green,
      startBlue: startColor.blue,
      startAlpha: startColor.alpha,
      endRed: endColor.red,
      endGreen: endColor.green,
      endBlue: endColor.blue,
      endAlpha: endColor.alpha,
      clip: clip.domainModel
    )
  }
}

extension ClockComponent {
  fileprivate var protoMessage: Ldtx_Program_V1_ClockComponent {
    var proto = Ldtx_Program_V1_ClockComponent()
    // Placement belongs to ProgramPreferences.video_layers_by_program_name.
    proto.showsSeconds = showsSeconds
    proto.uses24HourTime = uses24HourTime
    proto.foregroundColor = .color(
      red: foregroundRed,
      green: foregroundGreen,
      blue: foregroundBlue,
      alpha: foregroundAlpha
    )
    proto.backgroundColor = .color(
      red: backgroundRed,
      green: backgroundGreen,
      blue: backgroundBlue,
      alpha: backgroundAlpha
    )
    proto.showsDate = showsDate
    proto.usesSystemTimeZone = usesSystemTimeZone
    proto.utcOffsetMinutes = utcOffsetMinutes
    proto.background = background
    proto.outlines = outlines.prefix(2).map { outline in
      var protoOutline = Ldtx_Program_V1_ClockTextOutline()
      protoOutline.thickness = outline.thickness
      protoOutline.color = outline.color
      return protoOutline
    }
    return proto
  }
}

extension Ldtx_Program_V1_ClockComponent {
  fileprivate var domainModel: ClockComponent {
    var component = ClockComponent()
    if hasDestination {
      component.destinationX = destination.x
      component.destinationY = destination.y
      component.destinationWidth = destination.width
      component.destinationHeight = destination.height
    }
    if hasShowsSeconds {
      component.showsSeconds = showsSeconds
    }
    if hasUses24HourTime {
      component.uses24HourTime = uses24HourTime
    }
    if hasShowsDate { component.showsDate = showsDate }
    if hasUsesSystemTimeZone { component.usesSystemTimeZone = usesSystemTimeZone }
    component.utcOffsetMinutes = utcOffsetMinutes
    if !background.isEmpty { component.background = background }
    component.outlines = Array(outlines.prefix(2)).map {
      ClockTextOutline(thickness: $0.thickness, color: $0.color)
    }
    if hasForegroundColor {
      component.foregroundRed = foregroundColor.red
      component.foregroundGreen = foregroundColor.green
      component.foregroundBlue = foregroundColor.blue
      component.foregroundAlpha = foregroundColor.alpha
    }
    if hasBackgroundColor {
      component.backgroundRed = backgroundColor.red
      component.backgroundGreen = backgroundColor.green
      component.backgroundBlue = backgroundColor.blue
      component.backgroundAlpha = backgroundColor.alpha
    }
    return component
  }
}

extension InputDeviceComponent {
  fileprivate var protoMessage: Ldtx_Program_V1_InputDeviceComponent {
    var proto = Ldtx_Program_V1_InputDeviceComponent()
    if let inputDeviceID {
      proto.inputDeviceID = inputDeviceID
    }
    proto.sourceCrop = .sourceCrop(
      top: sourceCropTop,
      right: sourceCropRight,
      bottom: sourceCropBottom,
      left: sourceCropLeft
    )
    // Placement belongs to ProgramPreferences.video_layers_by_program_name.
    proto.backgroundRemovalEnabled = removesBackground
    return proto
  }
}

extension Ldtx_Program_V1_InputDeviceComponent {
  fileprivate var domainModel: InputDeviceComponent {
    var component = InputDeviceComponent(
      inputDeviceID: inputDeviceID.nilIfEmpty,
      sourceCropTop: sourceCrop.top,
      sourceCropRight: sourceCrop.right,
      sourceCropBottom: sourceCrop.bottom,
      sourceCropLeft: sourceCrop.left,
      removesBackground: backgroundRemovalEnabled
    )
    if hasDestination {
      component.destinationX = destination.x
      component.destinationY = destination.y
      component.destinationScale = destination.scale
    }
    return component
  }
}

extension InputAudioDeviceComponent {
  fileprivate var protoMessage: Ldtx_Program_V1_InputAudioDeviceComponent {
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

extension FillClip {
  fileprivate var protoMessage: Ldtx_Program_V1_Clip {
    .clip(top: top, right: right, bottom: bottom, left: left)
  }
}

extension Ldtx_Program_V1_Clip {
  fileprivate var domainModel: FillClip {
    FillClip(top: top, right: right, bottom: bottom, left: left)
  }
}

extension Ldtx_Program_V1_Point {
  fileprivate static func point(x: Float, y: Float) -> Ldtx_Program_V1_Point {
    var proto = Ldtx_Program_V1_Point()
    proto.x = x
    proto.y = y
    return proto
  }
}

extension Ldtx_Program_V1_DestinationRect {
  fileprivate static func destinationRect(
    x: Float,
    y: Float,
    width: Float,
    height: Float
  ) -> Self {
    var destination = Self()
    destination.x = x
    destination.y = y
    destination.width = width
    destination.height = height
    return destination
  }
}

extension Ldtx_Program_V1_Color {
  fileprivate static func color(red: Float, green: Float, blue: Float, alpha: Float)
    -> Ldtx_Program_V1_Color
  {
    var proto = Ldtx_Program_V1_Color()
    proto.red = red
    proto.green = green
    proto.blue = blue
    proto.alpha = alpha
    return proto
  }
}

extension Ldtx_Program_V1_SourceCrop {
  fileprivate static func sourceCrop(top: Float, right: Float, bottom: Float, left: Float)
    -> Ldtx_Program_V1_SourceCrop
  {
    var proto = Ldtx_Program_V1_SourceCrop()
    proto.top = top
    proto.right = right
    proto.bottom = bottom
    proto.left = left
    return proto
  }
}

extension Ldtx_Program_V1_Destination {
  fileprivate static func destination(x: Float, y: Float, scale: Float)
    -> Ldtx_Program_V1_Destination
  {
    var proto = Ldtx_Program_V1_Destination()
    proto.x = x
    proto.y = y
    proto.scale = scale
    return proto
  }
}

extension Ldtx_Program_V1_Clip {
  fileprivate static func clip(top: Float, right: Float, bottom: Float, left: Float)
    -> Ldtx_Program_V1_Clip
  {
    var proto = Ldtx_Program_V1_Clip()
    proto.top = top
    proto.right = right
    proto.bottom = bottom
    proto.left = left
    return proto
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
