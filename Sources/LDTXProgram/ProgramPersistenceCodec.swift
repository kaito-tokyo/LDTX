// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftProtobuf

public enum ProgramPersistenceCodec {
    public static func encodeProgramDefinitions(_ records: [SavedProgramDefinitionRecord]) throws -> Data {
        var library = Ldtx_Program_Persistence_V1_SavedProgramDefinitionLibrary()
        library.records = try records.map { try $0.protoMessage() }
        return try library.serializedData()
    }

    public static func decodeProgramDefinitions(from data: Data) throws -> [SavedProgramDefinitionRecord] {
        let library = try Ldtx_Program_Persistence_V1_SavedProgramDefinitionLibrary(serializedBytes: data)
        return library.records.map { $0.domainModel }
    }

    public static func encodeProgramArguments(_ records: [SavedProgramArgumentsRecord]) throws -> Data {
        var library = Ldtx_Program_Persistence_V1_SavedProgramArgumentsLibrary()
        library.records = records.map { $0.protoMessage }
        return try library.serializedData()
    }

    public static func decodeProgramArguments(from data: Data) throws -> [SavedProgramArgumentsRecord] {
        let library = try Ldtx_Program_Persistence_V1_SavedProgramArgumentsLibrary(serializedBytes: data)
        return library.records.map { $0.domainModel }
    }
}

private enum ProgramPersistenceCodecError: Error {
    case unsigned32OutOfRange(String, Int)
}

private extension SavedProgramDefinitionRecord {
    func protoMessage() throws -> Ldtx_Program_Persistence_V1_SavedProgramDefinitionRecord {
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

private extension Ldtx_Program_Persistence_V1_SavedProgramDefinitionRecord {
    var domainModel: SavedProgramDefinitionRecord {
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

private extension SavedProgramArgumentsRecord {
    var protoMessage: Ldtx_Program_Persistence_V1_SavedProgramArgumentsRecord {
        var proto = Ldtx_Program_Persistence_V1_SavedProgramArgumentsRecord()
        proto.name = name
        proto.arguments = arguments.protoMessage
        return proto
    }
}

private extension Ldtx_Program_Persistence_V1_SavedProgramArgumentsRecord {
    var domainModel: SavedProgramArgumentsRecord {
        SavedProgramArgumentsRecord(name: name, arguments: arguments.domainModel)
    }
}

private extension ProgramArguments {
    var protoMessage: Ldtx_Program_Persistence_V1_ProgramArguments {
        var proto = Ldtx_Program_Persistence_V1_ProgramArguments()
        proto.audioChannelGainsByName = audioChannelGainsByName
        return proto
    }
}

private extension ProgramInputDeviceRecord {
    func protoMessage() throws -> Ldtx_Program_Persistence_V1_InputDeviceRecord {
        var proto = Ldtx_Program_Persistence_V1_InputDeviceRecord()
        proto.id = id
        proto.name = name
        proto.kind = kind.protoValue
        if let physicalDeviceID {
            proto.physicalDeviceID = physicalDeviceID
        }
        proto.sideTrackRecordingPolicy = sideTrackRecordingPolicy.protoValue
        proto.backgroundRemovalPolicy = backgroundRemovalPolicy.protoValue
        proto.colorRangePolicy = colorRangePolicy.protoValue
        if let captureWidthOverride {
            proto.captureWidthOverride = try uint32(captureWidthOverride, field: "captureWidthOverride")
        }
        if let captureHeightOverride {
            proto.captureHeightOverride = try uint32(captureHeightOverride, field: "captureHeightOverride")
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

private extension Ldtx_Program_Persistence_V1_InputDeviceRecord {
    var domainModel: ProgramInputDeviceRecord {
        ProgramInputDeviceRecord(
            id: id.isEmpty ? UUID().uuidString : id,
            name: name,
            kind: kind.domainModel,
            physicalDeviceID: physicalDeviceID.nilIfEmpty,
            sideTrackRecordingPolicy: sideTrackRecordingPolicy.domainModel,
            backgroundRemovalPolicy: backgroundRemovalPolicy.domainModel,
            colorRangePolicy: colorRangePolicy.domainModel,
            captureWidthOverride: captureWidthOverride.nilIfZero,
            captureHeightOverride: captureHeightOverride.nilIfZero,
            captureFrameRateOverride: captureFrameRateOverride.nilIfZero
        )
    }
}

private extension UInt32 {
    var nilIfZero: Int? {
        self == 0 ? nil : Int(self)
    }
}

private extension ProgramInputDeviceKind {
    var protoValue: Ldtx_Program_Persistence_V1_InputDeviceKind {
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

private extension Ldtx_Program_Persistence_V1_InputDeviceKind {
    var domainModel: ProgramInputDeviceKind {
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

private extension ProgramSideTrackRecordingPolicy {
    var protoValue: Ldtx_Program_Persistence_V1_SideTrackRecordingPolicy {
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

private extension Ldtx_Program_Persistence_V1_SideTrackRecordingPolicy {
    var domainModel: ProgramSideTrackRecordingPolicy {
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

private extension ProgramInputDeviceBackgroundRemovalPolicy {
    var protoValue: Ldtx_Program_Persistence_V1_BackgroundRemovalPolicy {
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

private extension Ldtx_Program_Persistence_V1_BackgroundRemovalPolicy {
    var domainModel: ProgramInputDeviceBackgroundRemovalPolicy {
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

private extension ProgramInputDeviceColorRangePolicy {
    var protoValue: Ldtx_Program_Persistence_V1_ColorRangePolicy {
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

private extension Ldtx_Program_Persistence_V1_ColorRangePolicy {
    var domainModel: ProgramInputDeviceColorRangePolicy {
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

private extension Ldtx_Program_Persistence_V1_ProgramArguments {
    var domainModel: ProgramArguments {
        ProgramArguments(audioChannelGainsByName: audioChannelGainsByName)
    }
}

private extension CompositeProgramDefinition {
    var protoMessage: Ldtx_Program_V1_Program {
        var proto = Ldtx_Program_V1_Program()
        proto.components = steps.map(\.protoMessage)
        proto.audioChannels = audioChannels.map(\.protoMessage)
        if let programVideoPTSInputKey {
            proto.programVideoPtsInputKey = programVideoPTSInputKey
        }
        if let programAudioPTSInputKey {
            proto.programAudioPtsInputKey = programAudioPTSInputKey
        }
        return proto
    }
}

private extension Ldtx_Program_V1_Program {
    var domainModel: CompositeProgramDefinition {
        CompositeProgramDefinition(
            steps: components.map(\.domainModel),
            programVideoPTSInputKey: programVideoPtsInputKey.nilIfEmpty,
            programAudioPTSInputKey: programAudioPtsInputKey.nilIfEmpty,
            audioChannels: audioChannels.map(\.domainModel)
        )
    }
}

private extension CompositeProgramStep {
    var protoMessage: Ldtx_Program_V1_ProgramComponent {
        var proto = Ldtx_Program_V1_ProgramComponent()
        proto.id = id.uuidString.lowercased()
        if let displayName, !displayName.isEmpty {
            proto.name = displayName
        }
        switch component {
        case let .fillSolidColor(payload):
            proto.solidColorFill = payload.protoMessage
        case let .fillLinearGradient(payload):
            proto.linearGradientFill = payload.protoMessage
        case let .fillRadialGradient(payload):
            proto.radialGradientFill = payload.protoMessage
        case let .fillConicGradient(payload):
            proto.conicGradientFill = payload.protoMessage
        case let .inputCameraDevice(payload):
            proto.inputDevice = payload.protoMessage
        case .testPattern:
            proto.testPattern = Ldtx_Program_V1_TestPatternComponent()
        }
        return proto
    }
}

private extension Ldtx_Program_V1_ProgramComponent {
    var domainModel: CompositeProgramStep {
        let component: ProgramComponent
        switch definition {
        case let .solidColorFill(payload):
            component = .fillSolidColor(payload.domainModel)
        case let .linearGradientFill(payload):
            component = .fillLinearGradient(payload.domainModel)
        case let .radialGradientFill(payload):
            component = .fillRadialGradient(payload.domainModel)
        case let .conicGradientFill(payload):
            component = .fillConicGradient(payload.domainModel)
        case let .inputDevice(payload):
            component = .inputCameraDevice(payload.domainModel)
        case .testPattern:
            component = .testPattern
        case nil:
            component = .inputCameraDevice(InputDeviceComponent())
        }
        let id = UUID(uuidString: self.id) ?? UUID()
        return CompositeProgramStep(
            id: id,
            displayName: name.isEmpty ? nil : name,
            component: component
        )
    }
}

private extension ProgramAudioChannel {
    var protoMessage: Ldtx_Program_V1_ProgramAudioChannel {
        var proto = Ldtx_Program_V1_ProgramAudioChannel()
        proto.id = id.uuidString.lowercased()
        switch component {
        case let .inputAudioDevice(payload):
            proto.inputAudioDevice = payload.protoMessage
        case .silentAudio:
            proto.silentAudio = Ldtx_Program_V1_SilentAudioComponent()
        case .testPatternAudio:
            proto.testPatternAudio = Ldtx_Program_V1_TestPatternAudioComponent()
        }
        return proto
    }
}

private extension Ldtx_Program_V1_ProgramAudioChannel {
    var domainModel: ProgramAudioChannel {
        let component: ProgramAudioChannelComponent
        switch definition {
        case let .inputAudioDevice(payload):
            component = .inputAudioDevice(payload.domainModel)
        case .silentAudio:
            component = .silentAudio
        case .testPatternAudio:
            component = .testPatternAudio
        case nil:
            component = .inputAudioDevice(InputAudioDeviceComponent())
        }
        let id = UUID(uuidString: self.id) ?? UUID()
        return ProgramAudioChannel(id: id, component: component)
    }
}

private extension FillSolidColorComponent {
    var protoMessage: Ldtx_Program_V1_FillSolidColorComponent {
        var proto = Ldtx_Program_V1_FillSolidColorComponent()
        proto.color = .color(red: red, green: green, blue: blue, alpha: alpha)
        proto.clip = clip.protoMessage
        return proto
    }
}

private extension Ldtx_Program_V1_FillSolidColorComponent {
    var domainModel: FillSolidColorComponent {
        FillSolidColorComponent(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha,
            clip: clip.domainModel
        )
    }
}

private extension FillLinearGradientComponent {
    var protoMessage: Ldtx_Program_V1_FillLinearGradientComponent {
        var proto = Ldtx_Program_V1_FillLinearGradientComponent()
        proto.start = .point(x: startX, y: startY)
        proto.end = .point(x: endX, y: endY)
        proto.startColor = .color(red: startRed, green: startGreen, blue: startBlue, alpha: startAlpha)
        proto.endColor = .color(red: endRed, green: endGreen, blue: endBlue, alpha: endAlpha)
        proto.clip = clip.protoMessage
        return proto
    }
}

private extension Ldtx_Program_V1_FillLinearGradientComponent {
    var domainModel: FillLinearGradientComponent {
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

private extension FillRadialGradientComponent {
    var protoMessage: Ldtx_Program_V1_FillRadialGradientComponent {
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

private extension Ldtx_Program_V1_FillRadialGradientComponent {
    var domainModel: FillRadialGradientComponent {
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

private extension FillConicGradientComponent {
    var protoMessage: Ldtx_Program_V1_FillConicGradientComponent {
        var proto = Ldtx_Program_V1_FillConicGradientComponent()
        proto.center = .point(x: centerX, y: centerY)
        proto.startAngleRadians = startAngleRadians
        proto.startColor = .color(red: startRed, green: startGreen, blue: startBlue, alpha: startAlpha)
        proto.endColor = .color(red: endRed, green: endGreen, blue: endBlue, alpha: endAlpha)
        proto.clip = clip.protoMessage
        return proto
    }
}

private extension Ldtx_Program_V1_FillConicGradientComponent {
    var domainModel: FillConicGradientComponent {
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

private extension InputDeviceComponent {
    var protoMessage: Ldtx_Program_V1_InputDeviceComponent {
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
        proto.destination = .destination(x: destinationX, y: destinationY, scale: destinationScale)
        return proto
    }
}

private extension Ldtx_Program_V1_InputDeviceComponent {
    var domainModel: InputDeviceComponent {
        InputDeviceComponent(
            inputDeviceID: inputDeviceID.nilIfEmpty,
            sourceCropTop: sourceCrop.top,
            sourceCropRight: sourceCrop.right,
            sourceCropBottom: sourceCrop.bottom,
            sourceCropLeft: sourceCrop.left,
            destinationX: destination.x,
            destinationY: destination.y,
            destinationScale: destination.scale
        )
    }
}

private extension InputAudioDeviceComponent {
    var protoMessage: Ldtx_Program_V1_InputAudioDeviceComponent {
        var proto = Ldtx_Program_V1_InputAudioDeviceComponent()
        if let inputDeviceID {
            proto.inputDeviceID = inputDeviceID
        }
        return proto
    }
}

private extension Ldtx_Program_V1_InputAudioDeviceComponent {
    var domainModel: InputAudioDeviceComponent {
        InputAudioDeviceComponent(inputDeviceID: inputDeviceID.nilIfEmpty)
    }
}

private extension FillClip {
    var protoMessage: Ldtx_Program_V1_Clip {
        .clip(top: top, right: right, bottom: bottom, left: left)
    }
}

private extension Ldtx_Program_V1_Clip {
    var domainModel: FillClip {
        FillClip(top: top, right: right, bottom: bottom, left: left)
    }
}

private extension Ldtx_Program_V1_Point {
    static func point(x: Float, y: Float) -> Ldtx_Program_V1_Point {
        var proto = Ldtx_Program_V1_Point()
        proto.x = x
        proto.y = y
        return proto
    }
}

private extension Ldtx_Program_V1_Color {
    static func color(red: Float, green: Float, blue: Float, alpha: Float) -> Ldtx_Program_V1_Color {
        var proto = Ldtx_Program_V1_Color()
        proto.red = red
        proto.green = green
        proto.blue = blue
        proto.alpha = alpha
        return proto
    }
}

private extension Ldtx_Program_V1_SourceCrop {
    static func sourceCrop(top: Float, right: Float, bottom: Float, left: Float) -> Ldtx_Program_V1_SourceCrop {
        var proto = Ldtx_Program_V1_SourceCrop()
        proto.top = top
        proto.right = right
        proto.bottom = bottom
        proto.left = left
        return proto
    }
}

private extension Ldtx_Program_V1_Destination {
    static func destination(x: Float, y: Float, scale: Float) -> Ldtx_Program_V1_Destination {
        var proto = Ldtx_Program_V1_Destination()
        proto.x = x
        proto.y = y
        proto.scale = scale
        return proto
    }
}

private extension Ldtx_Program_V1_Clip {
    static func clip(top: Float, right: Float, bottom: Float, left: Float) -> Ldtx_Program_V1_Clip {
        var proto = Ldtx_Program_V1_Clip()
        proto.top = top
        proto.right = right
        proto.bottom = bottom
        proto.left = left
        return proto
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
