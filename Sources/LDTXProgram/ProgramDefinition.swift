// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum ProgramComponentDefinition: String, CaseIterable, Identifiable, Codable, Sendable {
    case inputCameraDevice
    case fillSolidColor
    case fillLinearGradient
    case fillRadialGradient
    case fillConicGradient
    case clock
    case testPattern

    public static let allCases: [ProgramComponentDefinition] = [
        .inputCameraDevice,
        .fillSolidColor,
        .fillLinearGradient,
        .fillRadialGradient,
        .fillConicGradient,
        .clock,
        .testPattern
    ]

    /// Components that can currently produce Program rendering commands.
    public static let renderableCases = allCases

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .inputCameraDevice:
            "Input Camera Device"
        case .fillSolidColor:
            "Fill Solid Color"
        case .fillLinearGradient:
            "Fill Linear Gradient"
        case .fillRadialGradient:
            "Fill Radial Gradient"
        case .fillConicGradient:
            "Fill Conic Gradient"
        case .clock:
            "Clock"
        case .testPattern:
            "Test Pattern"
        }
    }

    public var usesInputCameraDevice: Bool {
        switch self {
        case .inputCameraDevice:
            true
        default:
            false
        }
    }
}

public struct CompositeProgramDefinition: Codable, Equatable, Sendable {
    public var steps: [CompositeProgramStep]
    public var audioChannels: [ProgramAudioChannel]

    enum CodingKeys: String, CodingKey {
        case steps
        case audioChannels
    }

    public init(
        steps: [CompositeProgramStep] = [],
        audioChannels: [ProgramAudioChannel] = []
    ) {
        self.steps = steps
        self.audioChannels = audioChannels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        steps = try container.decodeIfPresent([CompositeProgramStep].self, forKey: .steps) ?? []
        audioChannels = try container.decodeIfPresent([ProgramAudioChannel].self, forKey: .audioChannels) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(steps, forKey: .steps)
        try container.encode(audioChannels, forKey: .audioChannels)
    }

    public func inputCameraDeviceMappingKey(for step: CompositeProgramStep) -> String {
        step.name
    }

    public func inputCameraDeviceDisplayName(for step: CompositeProgramStep) -> String {
        return step.name
    }

    public func videoComponentDisplayName(for step: CompositeProgramStep) -> String {
        return step.name
    }

    public func inputAudioDeviceMappingKey(for channel: ProgramAudioChannel) -> String {
        audioChannels.inputAudioDeviceMappingKey(for: channel)
    }

    public func audioChannelKey(for channel: ProgramAudioChannel) -> String {
        audioChannels.audioChannelKey(for: channel)
    }

    public func audioChannelDisplayName(for channel: ProgramAudioChannel) -> String {
        return audioChannels.audioChannelDisplayName(for: channel)
    }

    public mutating func renameInputDevice(from oldName: String, to newName: String) {
        for stepIndex in steps.indices {
            if case .inputCameraDevice(var component) = steps[stepIndex].component,
               component.inputDeviceID == oldName {
                component.inputDeviceID = newName
                steps[stepIndex].component = .inputCameraDevice(component)
            }
        }
        for channelIndex in audioChannels.indices {
            if case .inputAudioDevice(var component) = audioChannels[channelIndex].component,
               component.inputDeviceID == oldName {
                component.inputDeviceID = newName
                audioChannels[channelIndex].component = .inputAudioDevice(component)
            }
        }
    }

}

public struct ProgramPreferences: Codable, Equatable, Sendable {
    public static let minimumAudioChannelGainDecibels = -80.0
    public static let maximumAudioChannelGainDecibels = 20.0

    public static let minimumAudioChannelGain = pow(10.0, minimumAudioChannelGainDecibels / 20.0)
    public static let maximumAudioChannelGain = pow(10.0, maximumAudioChannelGainDecibels / 20.0)

    public var audioChannelGainsByName: [String: Double]
    public var videoMutedByInputDeviceName: [String: Bool]
    public var audioMutedByInputDeviceName: [String: Bool]

    enum CodingKeys: String, CodingKey {
        case audioChannelGainsByName
        case videoMutedByInputDeviceName
        case audioMutedByInputDeviceName
    }

    public init(
        audioChannelGainsByName: [String: Double] = [:],
        videoMutedByInputDeviceName: [String: Bool] = [:],
        audioMutedByInputDeviceName: [String: Bool] = [:]
    ) {
        self.audioChannelGainsByName = audioChannelGainsByName
        self.videoMutedByInputDeviceName = videoMutedByInputDeviceName
        self.audioMutedByInputDeviceName = audioMutedByInputDeviceName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioChannelGainsByName =
            try container.decodeIfPresent([String: Double].self, forKey: .audioChannelGainsByName) ?? [:]
        videoMutedByInputDeviceName =
            try container.decodeIfPresent([String: Bool].self, forKey: .videoMutedByInputDeviceName) ?? [:]
        audioMutedByInputDeviceName =
            try container.decodeIfPresent([String: Bool].self, forKey: .audioMutedByInputDeviceName) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(audioChannelGainsByName, forKey: .audioChannelGainsByName)
        try container.encode(videoMutedByInputDeviceName, forKey: .videoMutedByInputDeviceName)
        try container.encode(audioMutedByInputDeviceName, forKey: .audioMutedByInputDeviceName)
    }

    public func isVideoMuted(inputDeviceName: String) -> Bool {
        videoMutedByInputDeviceName[Self.preferenceKey(forName: inputDeviceName)] ?? false
    }

    public mutating func setVideoMuted(_ muted: Bool, inputDeviceName: String) {
        videoMutedByInputDeviceName[Self.preferenceKey(forName: inputDeviceName)] = muted
    }

    public func isAudioMuted(inputDeviceName: String) -> Bool {
        audioMutedByInputDeviceName[Self.preferenceKey(forName: inputDeviceName)] ?? false
    }

    public mutating func setAudioMuted(_ muted: Bool, inputDeviceName: String) {
        audioMutedByInputDeviceName[Self.preferenceKey(forName: inputDeviceName)] = muted
    }

    public mutating func renameInputDevice(from oldName: String, to newName: String) {
        let oldKey = Self.preferenceKey(forName: oldName)
        let newKey = Self.preferenceKey(forName: newName)
        guard oldKey != newKey else { return }
        if let value = videoMutedByInputDeviceName.removeValue(forKey: oldKey) {
            if videoMutedByInputDeviceName[newKey] != nil {
                videoMutedByInputDeviceName.removeAll()
            } else {
                videoMutedByInputDeviceName[newKey] = value
            }
        }
        if let value = audioMutedByInputDeviceName.removeValue(forKey: oldKey) {
            if audioMutedByInputDeviceName[newKey] != nil {
                // A destination key that is already present means persisted
                // mute state no longer has an unambiguous owner. Reset the
                // entire audio mute map rather than crashing during rename.
                audioMutedByInputDeviceName.removeAll()
            } else {
                audioMutedByInputDeviceName[newKey] = value
            }
        }
    }

    public mutating func removeInputDevice(named name: String) {
        videoMutedByInputDeviceName.removeValue(forKey: Self.preferenceKey(forName: name))
        audioMutedByInputDeviceName.removeValue(forKey: Self.preferenceKey(forName: name))
    }

    private static func preferenceKey(forName name: String) -> String {
        let hexadecimal = Array("0123456789ABCDEF".utf8)
        return String(decoding: name.utf8.flatMap { byte -> [UInt8] in
            let isUnreserved =
                (byte >= 0x41 && byte <= 0x5A) ||
                (byte >= 0x61 && byte <= 0x7A) ||
                (byte >= 0x30 && byte <= 0x39) ||
                byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
            guard !isUnreserved else { return [byte] }
            return [0x25, hexadecimal[Int(byte >> 4)], hexadecimal[Int(byte & 0x0F)]]
        }, as: UTF8.self)
    }

    public func audioChannelGain(for channel: ProgramAudioChannel, in composite: CompositeProgramDefinition) -> Double {
        audioChannelGain(for: channel, in: composite.audioChannels)
    }

    public func audioChannelGain(for channel: ProgramAudioChannel, in audioChannels: [ProgramAudioChannel]) -> Double {
        let key = audioChannels.audioChannelKey(for: channel)
        return Self.clampedAudioChannelGain(audioChannelGainsByName[key] ?? 1.0)
    }

    public func outputAudioChannelGain(
        for channel: ProgramAudioChannel,
        in audioChannels: [ProgramAudioChannel]
    ) -> Double {
        if case let .inputAudioDevice(payload) = channel.component,
           let inputDeviceID = payload.inputDeviceID,
           isAudioMuted(inputDeviceName: inputDeviceID) {
            return 0
        }
        return audioChannelGain(for: channel, in: audioChannels)
    }

    public mutating func setAudioChannelGain(
        _ gain: Double,
        for channel: ProgramAudioChannel,
        in composite: CompositeProgramDefinition
    ) {
        setAudioChannelGain(gain, for: channel, in: composite.audioChannels)
    }

    public mutating func setAudioChannelGain(
        _ gain: Double,
        for channel: ProgramAudioChannel,
        in audioChannels: [ProgramAudioChannel]
    ) {
        let key = audioChannels.audioChannelKey(for: channel)
        audioChannelGainsByName[key] = Self.clampedAudioChannelGain(gain)
    }

    public func audioChannelGainsByKey(for composite: CompositeProgramDefinition) -> [String: Double] {
        audioChannelGainsByKey(for: composite.audioChannels)
    }

    public func audioChannelGainsByKey(for audioChannels: [ProgramAudioChannel]) -> [String: Double] {
        var gainsByKey: [String: Double] = [:]
        for channel in audioChannels {
            let key = audioChannels.audioChannelKey(for: channel)
            gainsByKey[key] = Self.clampedAudioChannelGain(audioChannelGainsByName[key] ?? 1.0)
        }
        return gainsByKey
    }

    public static func linearAudioChannelGain(fromDecibels decibels: Double) -> Double {
        let clampedDecibels = min(
            max(decibels, minimumAudioChannelGainDecibels),
            maximumAudioChannelGainDecibels
        )
        return pow(10.0, clampedDecibels / 20.0)
    }

    public static func audioChannelGainDecibels(fromLinearGain gain: Double) -> Double {
        20.0 * log10(clampedAudioChannelGain(gain))
    }

    public static func clampedAudioChannelGain(_ gain: Double) -> Double {
        guard gain.isFinite else {
            return 1.0
        }
        return min(max(gain, minimumAudioChannelGain), maximumAudioChannelGain)
    }
}

public extension [ProgramAudioChannel] {
    func inputAudioDeviceMappingKey(for channel: ProgramAudioChannel) -> String {
        audioChannelKey(for: channel)
    }

    func audioChannelKey(for channel: ProgramAudioChannel) -> String {
        channel.name
    }

    func audioChannelDisplayName(for channel: ProgramAudioChannel) -> String {
        channel.name
    }

}

public extension [ProgramInputDeviceRecord] {
    func resolvedWorkspaceAudioChannels(
        from storedAudioChannels: [ProgramAudioChannel]
    ) -> [ProgramAudioChannel] {
        let audioInputDevices = filter { $0.kind == .audio }
        let audioInputDeviceIDs = Set(audioInputDevices.map(\.id))
        var representedInputDeviceIDs: Set<String> = []
        var resolvedAudioChannels: [ProgramAudioChannel] = []

        for channel in storedAudioChannels {
            switch channel.component {
            case let .inputAudioDevice(payload):
                guard let inputDeviceID = payload.inputDeviceID,
                      audioInputDeviceIDs.contains(inputDeviceID),
                      representedInputDeviceIDs.insert(inputDeviceID).inserted else {
                    continue
                }
                resolvedAudioChannels.append(channel)
            case .silentAudio, .testPatternAudio:
                resolvedAudioChannels.append(channel)
            }
        }

        for inputDevice in audioInputDevices
        where !representedInputDeviceIDs.contains(inputDevice.id) {
            resolvedAudioChannels.append(
                ProgramAudioChannel(
                    name: inputDevice.name,
                    component: .inputAudioDevice(
                        InputAudioDeviceComponent(inputDeviceID: inputDevice.id)
                    )
                )
            )
        }

        return resolvedAudioChannels
    }

}

public struct CompositeProgramStep: Codable, Equatable, Sendable {
    public var name: String
    public var component: ProgramComponent

    public var id: String { name }
    public var displayName: String? {
        get { name }
        set { if let newValue, !newValue.isEmpty { name = newValue } }
    }

    enum CodingKeys: String, CodingKey {
        case name
        case component
    }

    public init(
        id: String = "",
        displayName: String? = nil,
        component: ProgramComponent = .inputCameraDevice(InputDeviceComponent())
    ) {
        name = displayName ?? (id.isEmpty ? component.definition.displayName : id)
        self.component = component
    }

    public init(id: String = "", component: ProgramComponent) {
        self.init(id: id, displayName: nil, component: component)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        component = try container.decodeIfPresent(ProgramComponent.self, forKey: .component) ??
            .inputCameraDevice(InputDeviceComponent())
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? component.definition.displayName
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(component, forKey: .component)
    }

    public static func == (lhs: CompositeProgramStep, rhs: CompositeProgramStep) -> Bool {
        lhs.name == rhs.name && lhs.component == rhs.component
    }
}

public protocol ProgramComponentParameters: Codable, Equatable, Sendable {}

public extension ProgramComponentParameters {
    func encodeComponentParameters(to encoder: Encoder) throws {
        try encode(to: encoder)
    }
}

private struct EmptyProgramComponentParameters: ProgramComponentParameters {}

public enum ProgramAudioChannelDefinition: String, CaseIterable, Identifiable, Codable, Sendable {
    case inputAudioDevice
    case silentAudio
    case testPatternAudio

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .inputAudioDevice:
            "Input Audio Device"
        case .silentAudio:
            "Silent Audio"
        case .testPatternAudio:
            "Test Pattern Audio"
        }
    }

    public var usesInputAudioDevice: Bool {
        switch self {
        case .inputAudioDevice:
            true
        case .silentAudio, .testPatternAudio:
            false
        }
    }
}

public struct ProgramAudioChannel: Codable, Equatable, Sendable {
    public var name: String
    public var component: ProgramAudioChannelComponent

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case component
    }

    public init(
        id: String = "",
        name: String? = nil,
        component: ProgramAudioChannelComponent = .inputAudioDevice(InputAudioDeviceComponent())
    ) {
        self.name = name ?? (id.isEmpty ? component.definition.displayName : id)
        self.component = component
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        component = try container.decodeIfPresent(ProgramAudioChannelComponent.self, forKey: .component) ??
            .inputAudioDevice(InputAudioDeviceComponent())
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? component.definition.displayName
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(component, forKey: .component)
    }

    public static func == (lhs: ProgramAudioChannel, rhs: ProgramAudioChannel) -> Bool {
        lhs.name == rhs.name && lhs.component == rhs.component
    }
}

public enum ProgramAudioChannelComponent: Codable, Equatable, Sendable {
    case inputAudioDevice(InputAudioDeviceComponent)
    case silentAudio
    case testPatternAudio

    enum CodingKeys: String, CodingKey {
        case id
        case parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let definition = try container.decode(ProgramAudioChannelDefinition.self, forKey: .id)
        switch definition {
        case .inputAudioDevice:
            self = .inputAudioDevice(
                try container.decodeIfPresent(InputAudioDeviceComponent.self, forKey: .parameters) ?? InputAudioDeviceComponent()
            )
        case .silentAudio:
            self = .silentAudio
        case .testPatternAudio:
            self = .testPatternAudio
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(definition, forKey: .id)
        try encodeParameters(to: container.superEncoder(forKey: .parameters))
    }

    public func encodeParameters(to encoder: Encoder) throws {
        switch self {
        case let .inputAudioDevice(payload):
            try payload.encodeComponentParameters(to: encoder)
        case .silentAudio:
            try EmptyProgramComponentParameters().encodeComponentParameters(to: encoder)
        case .testPatternAudio:
            try EmptyProgramComponentParameters().encodeComponentParameters(to: encoder)
        }
    }

    public static func defaultComponent(for definition: ProgramAudioChannelDefinition) -> ProgramAudioChannelComponent {
        switch definition {
        case .inputAudioDevice:
            .inputAudioDevice(InputAudioDeviceComponent())
        case .silentAudio:
            .silentAudio
        case .testPatternAudio:
            .testPatternAudio
        }
    }

    public var definition: ProgramAudioChannelDefinition {
        switch self {
        case .inputAudioDevice:
            .inputAudioDevice
        case .silentAudio:
            .silentAudio
        case .testPatternAudio:
            .testPatternAudio
        }
    }
}

public struct InputAudioDeviceComponent: ProgramComponentParameters {
    public var inputDeviceID: String?

    enum CodingKeys: String, CodingKey {
        case inputDeviceID
    }

    public init(inputDeviceID: String? = nil) {
        self.inputDeviceID = inputDeviceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputDeviceID = try container.decodeIfPresent(String.self, forKey: .inputDeviceID)
    }
}

private struct CSSRGBAColor: Codable, Equatable, Sendable {
    var red: Float
    var green: Float
    var blue: Float
    var alpha: Float

    init(red: Float, green: Float, blue: Float, alpha: Float) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let color = Self.parse(string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected rgba(<red> <green> <blue> / <alpha>) with RGB integers 0...255 and alpha 0...1."
            )
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(cssString)
    }

    private var cssString: String {
        let red = Self.u8String(red)
        let green = Self.u8String(green)
        let blue = Self.u8String(blue)
        let alpha = Self.alphaString(alpha)
        return "rgba(\(red) \(green) \(blue) / \(alpha))"
    }

    private static func parse(_ string: String) -> CSSRGBAColor? {
        let prefix = "rgba("
        let suffix = ")"
        guard string.hasPrefix(prefix), string.hasSuffix(suffix) else {
            return nil
        }
        let body = String(string.dropFirst(prefix.count).dropLast(suffix.count))
        let parts = body.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[3] == "/",
              let red = UInt8(parts[0]),
              let green = UInt8(parts[1]),
              let blue = UInt8(parts[2]),
              let alpha = Float(parts[4]),
              alpha >= 0,
              alpha <= 1 else {
            return nil
        }
        return CSSRGBAColor(
            red: Float(red) / 255,
            green: Float(green) / 255,
            blue: Float(blue) / 255,
            alpha: alpha
        )
    }

    private static func u8String(_ value: Float) -> String {
        String(min(max(Int((value * 255).rounded()), 0), 255))
    }

    private static func alphaString(_ value: Float) -> String {
        let clamped = min(max(value, 0), 1)
        if clamped == 0 || clamped == 1 {
            return String(Int(clamped))
        }
        return String(format: "%.6g", Double(clamped))
    }
}

public enum ProgramComponent: Codable, Equatable, Sendable {
    case fillSolidColor(FillSolidColorComponent)
    case fillLinearGradient(FillLinearGradientComponent)
    case fillRadialGradient(FillRadialGradientComponent)
    case fillConicGradient(FillConicGradientComponent)
    case clock(ClockComponent)
    case inputCameraDevice(InputDeviceComponent)
    case testPattern

    enum CodingKeys: String, CodingKey {
        case id
        case parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let definition = try container.decode(ProgramComponentDefinition.self, forKey: .id)
        switch definition {
        case .fillSolidColor:
            self = .fillSolidColor(try container.decode(FillSolidColorComponent.self, forKey: .parameters))
        case .fillLinearGradient:
            self = .fillLinearGradient(try container.decode(FillLinearGradientComponent.self, forKey: .parameters))
        case .fillRadialGradient:
            self = .fillRadialGradient(try container.decode(FillRadialGradientComponent.self, forKey: .parameters))
        case .fillConicGradient:
            self = .fillConicGradient(try container.decode(FillConicGradientComponent.self, forKey: .parameters))
        case .clock:
            self = .clock(try container.decodeIfPresent(ClockComponent.self, forKey: .parameters) ?? ClockComponent())
        case .inputCameraDevice:
            self = .inputCameraDevice(try container.decode(InputDeviceComponent.self, forKey: .parameters))
        case .testPattern:
            self = .testPattern
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(definition, forKey: .id)
        try encodeParameters(to: container.superEncoder(forKey: .parameters))
    }

    public func encodeParameters(to encoder: Encoder) throws {
        switch self {
        case let .fillSolidColor(payload):
            try payload.encodeComponentParameters(to: encoder)
        case let .fillLinearGradient(payload):
            try payload.encodeComponentParameters(to: encoder)
        case let .fillRadialGradient(payload):
            try payload.encodeComponentParameters(to: encoder)
        case let .fillConicGradient(payload):
            try payload.encodeComponentParameters(to: encoder)
        case let .clock(payload):
            try payload.encodeComponentParameters(to: encoder)
        case let .inputCameraDevice(payload):
            try payload.encodeComponentParameters(to: encoder)
        case .testPattern:
            try EmptyProgramComponentParameters().encodeComponentParameters(to: encoder)
        }
    }

    public static func defaultComponent(for definition: ProgramComponentDefinition) -> ProgramComponent {
        switch definition {
        case .fillSolidColor:
            .fillSolidColor(FillSolidColorComponent())
        case .fillLinearGradient:
            .fillLinearGradient(FillLinearGradientComponent())
        case .fillRadialGradient:
            .fillRadialGradient(FillRadialGradientComponent())
        case .fillConicGradient:
            .fillConicGradient(FillConicGradientComponent())
        case .clock:
            .clock(ClockComponent())
        case .inputCameraDevice:
            .inputCameraDevice(InputDeviceComponent())
        case .testPattern:
            .testPattern
        }
    }

    public var definition: ProgramComponentDefinition {
        switch self {
        case .fillSolidColor:
            .fillSolidColor
        case .fillLinearGradient:
            .fillLinearGradient
        case .fillRadialGradient:
            .fillRadialGradient
        case .fillConicGradient:
            .fillConicGradient
        case .clock:
            .clock
        case .inputCameraDevice:
            .inputCameraDevice
        case .testPattern:
            .testPattern
        }
    }
}

public struct FillSolidColorComponent: ProgramComponentParameters {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float
    public var clip: FillClip

    enum CodingKeys: String, CodingKey {
        case color0
        case clip
    }

    public init(
        red: Float = 0.95,
        green: Float = 0.20,
        blue: Float = 0.18,
        alpha: Float = 1,
        clip: FillClip = FillClip()
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.clip = clip
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let color0 = try container.decode(CSSRGBAColor.self, forKey: .color0)
        red = color0.red
        green = color0.green
        blue = color0.blue
        alpha = color0.alpha
        clip = try container.decodeIfPresent(FillClip.self, forKey: .clip) ?? FillClip()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CSSRGBAColor(red: red, green: green, blue: blue, alpha: alpha), forKey: .color0)
        try container.encode(clip, forKey: .clip)
    }
}

public struct FillLinearGradientComponent: ProgramComponentParameters {
    public var startX: Float
    public var startY: Float
    public var endX: Float
    public var endY: Float
    public var startRed: Float
    public var startGreen: Float
    public var startBlue: Float
    public var startAlpha: Float
    public var endRed: Float
    public var endGreen: Float
    public var endBlue: Float
    public var endAlpha: Float
    public var clip: FillClip

    enum CodingKeys: String, CodingKey {
        case startX
        case startY
        case endX
        case endY
        case color0
        case color1
        case clip
    }

    public init(
        startX: Float = 0,
        startY: Float = 0,
        endX: Float = 1,
        endY: Float = 1,
        startRed: Float = 0.10,
        startGreen: Float = 0.72,
        startBlue: Float = 0.95,
        startAlpha: Float = 1,
        endRed: Float = 0.08,
        endGreen: Float = 0.16,
        endBlue: Float = 0.50,
        endAlpha: Float = 1,
        clip: FillClip = FillClip()
    ) {
        self.startX = startX
        self.startY = startY
        self.endX = endX
        self.endY = endY
        self.startRed = startRed
        self.startGreen = startGreen
        self.startBlue = startBlue
        self.startAlpha = startAlpha
        self.endRed = endRed
        self.endGreen = endGreen
        self.endBlue = endBlue
        self.endAlpha = endAlpha
        self.clip = clip
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startX = try container.decode(Float.self, forKey: .startX)
        startY = try container.decode(Float.self, forKey: .startY)
        endX = try container.decode(Float.self, forKey: .endX)
        endY = try container.decode(Float.self, forKey: .endY)
        let color0 = try container.decode(CSSRGBAColor.self, forKey: .color0)
        startRed = color0.red
        startGreen = color0.green
        startBlue = color0.blue
        startAlpha = color0.alpha
        let color1 = try container.decode(CSSRGBAColor.self, forKey: .color1)
        endRed = color1.red
        endGreen = color1.green
        endBlue = color1.blue
        endAlpha = color1.alpha
        clip = try container.decodeIfPresent(FillClip.self, forKey: .clip) ?? FillClip()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startX, forKey: .startX)
        try container.encode(startY, forKey: .startY)
        try container.encode(endX, forKey: .endX)
        try container.encode(endY, forKey: .endY)
        try container.encode(CSSRGBAColor(red: startRed, green: startGreen, blue: startBlue, alpha: startAlpha), forKey: .color0)
        try container.encode(CSSRGBAColor(red: endRed, green: endGreen, blue: endBlue, alpha: endAlpha), forKey: .color1)
        try container.encode(clip, forKey: .clip)
    }
}

public struct FillRadialGradientComponent: ProgramComponentParameters {
    public var centerX: Float
    public var centerY: Float
    public var innerRadius: Float
    public var outerRadius: Float
    public var innerRed: Float
    public var innerGreen: Float
    public var innerBlue: Float
    public var innerAlpha: Float
    public var outerRed: Float
    public var outerGreen: Float
    public var outerBlue: Float
    public var outerAlpha: Float
    public var clip: FillClip

    enum CodingKeys: String, CodingKey {
        case centerX
        case centerY
        case innerRadius
        case outerRadius
        case color0
        case color1
        case clip
    }

    public init(
        centerX: Float = 0.5,
        centerY: Float = 0.5,
        innerRadius: Float = 0,
        outerRadius: Float = 0.72,
        innerRed: Float = 0.96,
        innerGreen: Float = 0.96,
        innerBlue: Float = 0.98,
        innerAlpha: Float = 1,
        outerRed: Float = 0.42,
        outerGreen: Float = 0.10,
        outerBlue: Float = 0.80,
        outerAlpha: Float = 1,
        clip: FillClip = FillClip()
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.innerRed = innerRed
        self.innerGreen = innerGreen
        self.innerBlue = innerBlue
        self.innerAlpha = innerAlpha
        self.outerRed = outerRed
        self.outerGreen = outerGreen
        self.outerBlue = outerBlue
        self.outerAlpha = outerAlpha
        self.clip = clip
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        centerX = try container.decode(Float.self, forKey: .centerX)
        centerY = try container.decode(Float.self, forKey: .centerY)
        innerRadius = try container.decode(Float.self, forKey: .innerRadius)
        outerRadius = try container.decode(Float.self, forKey: .outerRadius)
        let color0 = try container.decode(CSSRGBAColor.self, forKey: .color0)
        innerRed = color0.red
        innerGreen = color0.green
        innerBlue = color0.blue
        innerAlpha = color0.alpha
        let color1 = try container.decode(CSSRGBAColor.self, forKey: .color1)
        outerRed = color1.red
        outerGreen = color1.green
        outerBlue = color1.blue
        outerAlpha = color1.alpha
        clip = try container.decodeIfPresent(FillClip.self, forKey: .clip) ?? FillClip()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(centerX, forKey: .centerX)
        try container.encode(centerY, forKey: .centerY)
        try container.encode(innerRadius, forKey: .innerRadius)
        try container.encode(outerRadius, forKey: .outerRadius)
        try container.encode(CSSRGBAColor(red: innerRed, green: innerGreen, blue: innerBlue, alpha: innerAlpha), forKey: .color0)
        try container.encode(CSSRGBAColor(red: outerRed, green: outerGreen, blue: outerBlue, alpha: outerAlpha), forKey: .color1)
        try container.encode(clip, forKey: .clip)
    }
}

public struct FillConicGradientComponent: ProgramComponentParameters {
    public var centerX: Float
    public var centerY: Float
    public var startAngleRadians: Float
    public var startRed: Float
    public var startGreen: Float
    public var startBlue: Float
    public var startAlpha: Float
    public var endRed: Float
    public var endGreen: Float
    public var endBlue: Float
    public var endAlpha: Float
    public var clip: FillClip

    enum CodingKeys: String, CodingKey {
        case centerX
        case centerY
        case startAngleRadians
        case color0
        case color1
        case clip
    }

    public init(
        centerX: Float = 0.5,
        centerY: Float = 0.5,
        startAngleRadians: Float = 0,
        startRed: Float = 0.95,
        startGreen: Float = 0.18,
        startBlue: Float = 0.60,
        startAlpha: Float = 1,
        endRed: Float = 0.12,
        endGreen: Float = 0.75,
        endBlue: Float = 0.90,
        endAlpha: Float = 1,
        clip: FillClip = FillClip()
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.startAngleRadians = startAngleRadians
        self.startRed = startRed
        self.startGreen = startGreen
        self.startBlue = startBlue
        self.startAlpha = startAlpha
        self.endRed = endRed
        self.endGreen = endGreen
        self.endBlue = endBlue
        self.endAlpha = endAlpha
        self.clip = clip
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        centerX = try container.decode(Float.self, forKey: .centerX)
        centerY = try container.decode(Float.self, forKey: .centerY)
        startAngleRadians = try container.decode(Float.self, forKey: .startAngleRadians)
        let color0 = try container.decode(CSSRGBAColor.self, forKey: .color0)
        startRed = color0.red
        startGreen = color0.green
        startBlue = color0.blue
        startAlpha = color0.alpha
        let color1 = try container.decode(CSSRGBAColor.self, forKey: .color1)
        endRed = color1.red
        endGreen = color1.green
        endBlue = color1.blue
        endAlpha = color1.alpha
        clip = try container.decodeIfPresent(FillClip.self, forKey: .clip) ?? FillClip()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(centerX, forKey: .centerX)
        try container.encode(centerY, forKey: .centerY)
        try container.encode(startAngleRadians, forKey: .startAngleRadians)
        try container.encode(CSSRGBAColor(red: startRed, green: startGreen, blue: startBlue, alpha: startAlpha), forKey: .color0)
        try container.encode(CSSRGBAColor(red: endRed, green: endGreen, blue: endBlue, alpha: endAlpha), forKey: .color1)
        try container.encode(clip, forKey: .clip)
    }
}

/// A bounded local-time presentation rather than an unrestricted text API.
///
/// Coordinates are normalized to the Program canvas. The Clock runtime reads
/// its own current-time provider; frame timestamps are intentionally absent
/// from this persisted definition.
public struct ClockComponent: ProgramComponentParameters {
    public var destinationX: Float
    public var destinationY: Float
    public var destinationWidth: Float
    public var destinationHeight: Float
    public var showsSeconds: Bool
    public var uses24HourTime: Bool
    public var foregroundRed: Float
    public var foregroundGreen: Float
    public var foregroundBlue: Float
    public var foregroundAlpha: Float
    public var backgroundRed: Float
    public var backgroundGreen: Float
    public var backgroundBlue: Float
    public var backgroundAlpha: Float

    enum CodingKeys: String, CodingKey {
        case destinationX
        case destinationY
        case destinationWidth
        case destinationHeight
        case showsSeconds
        case uses24HourTime
        case foregroundColor
        case backgroundColor
    }

    public init(
        destinationX: Float = 0.05,
        destinationY: Float = 0.05,
        destinationWidth: Float = 0.32,
        destinationHeight: Float = 0.12,
        showsSeconds: Bool = true,
        uses24HourTime: Bool = true,
        foregroundRed: Float = 1,
        foregroundGreen: Float = 1,
        foregroundBlue: Float = 1,
        foregroundAlpha: Float = 1,
        backgroundRed: Float = 0,
        backgroundGreen: Float = 0,
        backgroundBlue: Float = 0,
        backgroundAlpha: Float = 0.65
    ) {
        self.destinationX = destinationX
        self.destinationY = destinationY
        self.destinationWidth = destinationWidth
        self.destinationHeight = destinationHeight
        self.showsSeconds = showsSeconds
        self.uses24HourTime = uses24HourTime
        self.foregroundRed = foregroundRed
        self.foregroundGreen = foregroundGreen
        self.foregroundBlue = foregroundBlue
        self.foregroundAlpha = foregroundAlpha
        self.backgroundRed = backgroundRed
        self.backgroundGreen = backgroundGreen
        self.backgroundBlue = backgroundBlue
        self.backgroundAlpha = backgroundAlpha
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        destinationX = try container.decodeIfPresent(Float.self, forKey: .destinationX) ?? 0.05
        destinationY = try container.decodeIfPresent(Float.self, forKey: .destinationY) ?? 0.05
        destinationWidth = try container.decodeIfPresent(Float.self, forKey: .destinationWidth) ?? 0.32
        destinationHeight = try container.decodeIfPresent(Float.self, forKey: .destinationHeight) ?? 0.12
        showsSeconds = try container.decodeIfPresent(Bool.self, forKey: .showsSeconds) ?? true
        uses24HourTime = try container.decodeIfPresent(Bool.self, forKey: .uses24HourTime) ?? true
        let foreground = try container.decodeIfPresent(CSSRGBAColor.self, forKey: .foregroundColor) ??
            CSSRGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        foregroundRed = foreground.red
        foregroundGreen = foreground.green
        foregroundBlue = foreground.blue
        foregroundAlpha = foreground.alpha
        let background = try container.decodeIfPresent(CSSRGBAColor.self, forKey: .backgroundColor) ??
            CSSRGBAColor(red: 0, green: 0, blue: 0, alpha: 0.65)
        backgroundRed = background.red
        backgroundGreen = background.green
        backgroundBlue = background.blue
        backgroundAlpha = background.alpha
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(destinationX, forKey: .destinationX)
        try container.encode(destinationY, forKey: .destinationY)
        try container.encode(destinationWidth, forKey: .destinationWidth)
        try container.encode(destinationHeight, forKey: .destinationHeight)
        try container.encode(showsSeconds, forKey: .showsSeconds)
        try container.encode(uses24HourTime, forKey: .uses24HourTime)
        try container.encode(
            CSSRGBAColor(
                red: foregroundRed,
                green: foregroundGreen,
                blue: foregroundBlue,
                alpha: foregroundAlpha
            ),
            forKey: .foregroundColor
        )
        try container.encode(
            CSSRGBAColor(
                red: backgroundRed,
                green: backgroundGreen,
                blue: backgroundBlue,
                alpha: backgroundAlpha
            ),
            forKey: .backgroundColor
        )
    }
}

public struct FillClip: Codable, Equatable, Sendable {
    public var top: Float
    public var right: Float
    public var bottom: Float
    public var left: Float

    public init(top: Float = 0, right: Float = 0, bottom: Float = 0, left: Float = 0) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }
}

/// The placement of an input video component on the Program canvas.
///
/// This is deliberately distinct from the input processing parameters.  A
/// Destination is consumed directly by the compositor command encoder, while
/// crop and background removal describe the input pipeline that produces the
/// source texture.
public struct InputDeviceDestination: Codable, Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var scale: Float

    public init(x: Float = 0, y: Float = 0, scale: Float = 1) {
        self.x = x
        self.y = y
        self.scale = scale
    }
}

public struct InputDeviceComponent: ProgramComponentParameters {
    public var inputDeviceID: String?
    public var sourceCropTop: Float
    public var sourceCropRight: Float
    public var sourceCropBottom: Float
    public var sourceCropLeft: Float
    public var destinationX: Float
    public var destinationY: Float
    public var destinationScale: Float
    public var removesBackground: Bool

    enum CodingKeys: String, CodingKey {
        case inputDeviceID
        case sourceCropTop
        case sourceCropRight
        case sourceCropBottom
        case sourceCropLeft
        case destinationX
        case destinationY
        case destinationScale
        case removesBackground
    }

    public init(
        inputDeviceID: String? = nil,
        sourceCropTop: Float = 0,
        sourceCropRight: Float = 0,
        sourceCropBottom: Float = 0,
        sourceCropLeft: Float = 0,
        destinationX: Float = 0,
        destinationY: Float = 0,
        destinationScale: Float = 1,
        removesBackground: Bool = false
    ) {
        self.inputDeviceID = inputDeviceID
        self.sourceCropTop = sourceCropTop
        self.sourceCropRight = sourceCropRight
        self.sourceCropBottom = sourceCropBottom
        self.sourceCropLeft = sourceCropLeft
        self.destinationX = destinationX
        self.destinationY = destinationY
        self.destinationScale = destinationScale
        self.removesBackground = removesBackground
    }

    public var destination: InputDeviceDestination {
        get {
            InputDeviceDestination(
                x: destinationX,
                y: destinationY,
                scale: destinationScale
            )
        }
        set {
            destinationX = newValue.x
            destinationY = newValue.y
            destinationScale = newValue.scale
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputDeviceID = try container.decodeIfPresent(String.self, forKey: .inputDeviceID)
        sourceCropTop = try container.decodeIfPresent(Float.self, forKey: .sourceCropTop) ?? 0
        sourceCropRight = try container.decodeIfPresent(Float.self, forKey: .sourceCropRight) ?? 0
        sourceCropBottom = try container.decodeIfPresent(Float.self, forKey: .sourceCropBottom) ?? 0
        sourceCropLeft = try container.decodeIfPresent(Float.self, forKey: .sourceCropLeft) ?? 0
        destinationX = try container.decodeIfPresent(Float.self, forKey: .destinationX) ?? 0
        destinationY = try container.decodeIfPresent(Float.self, forKey: .destinationY) ?? 0
        destinationScale = try container.decodeIfPresent(Float.self, forKey: .destinationScale) ?? 1
        removesBackground = try container.decodeIfPresent(Bool.self, forKey: .removesBackground) ?? false
    }
}

public struct SavedProgramDefinitionRecord: Codable, Equatable, Sendable {
    public var name: String
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var frameRateNumerator: Int
    public var frameRateDenominator: Int
    public var composite: CompositeProgramDefinition
    public var inputDevices: [ProgramInputDeviceRecord]

    public init(
        name: String,
        canvasWidth: Int,
        canvasHeight: Int,
        frameRateNumerator: Int,
        frameRateDenominator: Int,
        composite: CompositeProgramDefinition,
        inputDevices: [ProgramInputDeviceRecord] = []
    ) {
        self.name = name
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.frameRateNumerator = frameRateNumerator
        self.frameRateDenominator = frameRateDenominator
        self.composite = composite
        self.inputDevices = inputDevices
    }

}

public struct ProgramInputDeviceRecord: Codable, Equatable, Sendable {
    public var name: String
    public var kind: ProgramInputDeviceKind
    public var physicalDeviceID: String?
    public var backgroundRemovalPolicy: ProgramInputDeviceBackgroundRemovalPolicy
    public var colorRangePolicy: ProgramInputDeviceColorRangePolicy
    public var captureWidthOverride: Int?
    public var captureHeightOverride: Int?
    public var captureFrameRateOverride: Int?

    public init(
        id: String = "",
        name: String,
        kind: ProgramInputDeviceKind,
        physicalDeviceID: String? = nil,
        backgroundRemovalPolicy: ProgramInputDeviceBackgroundRemovalPolicy = .unspecified,
        colorRangePolicy: ProgramInputDeviceColorRangePolicy = .unspecified,
        captureWidthOverride: Int? = nil,
        captureHeightOverride: Int? = nil,
        captureFrameRateOverride: Int? = nil
    ) {
        self.name = name
        self.kind = kind
        self.physicalDeviceID = physicalDeviceID
        self.backgroundRemovalPolicy = backgroundRemovalPolicy
        self.colorRangePolicy = colorRangePolicy
        self.captureWidthOverride = captureWidthOverride
        self.captureHeightOverride = captureHeightOverride
        self.captureFrameRateOverride = captureFrameRateOverride
    }

    enum CodingKeys: String, CodingKey {
        case name
        case kind
        case physicalDeviceID
        case backgroundRemovalPolicy
        case colorRangePolicy
        case captureWidthOverride
        case captureHeightOverride
        case captureFrameRateOverride
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(ProgramInputDeviceKind.self, forKey: .kind)
        physicalDeviceID = try container.decodeIfPresent(String.self, forKey: .physicalDeviceID)
        backgroundRemovalPolicy =
            try container.decodeIfPresent(
                ProgramInputDeviceBackgroundRemovalPolicy.self,
                forKey: .backgroundRemovalPolicy
            ) ?? .unspecified
        colorRangePolicy =
            try container.decodeIfPresent(
                ProgramInputDeviceColorRangePolicy.self,
                forKey: .colorRangePolicy
            ) ?? .unspecified
        captureWidthOverride = try container.decodeIfPresent(Int.self, forKey: .captureWidthOverride)
        captureHeightOverride = try container.decodeIfPresent(Int.self, forKey: .captureHeightOverride)
        captureFrameRateOverride = try container.decodeIfPresent(Int.self, forKey: .captureFrameRateOverride)
    }

    /// Names are the stable identity of workspace input devices.
    public var id: String { name }

    public var removesBackground: Bool {
        backgroundRemovalPolicy.removesBackground
    }

    public mutating func setRemovesBackground(_ removesBackground: Bool) {
        backgroundRemovalPolicy = removesBackground ? .enabled : .disabled
    }

    public var hasCaptureOverrides: Bool {
        colorRangePolicy != .unspecified ||
            captureWidthOverride != nil ||
            captureHeightOverride != nil ||
            captureFrameRateOverride != nil
    }

    public mutating func clearCaptureOverrides() {
        colorRangePolicy = .unspecified
        captureWidthOverride = nil
        captureHeightOverride = nil
        captureFrameRateOverride = nil
    }
}

extension ProgramInputDeviceRecord: Identifiable {}

public enum ProgramInputDeviceKind: String, CaseIterable, Codable, Equatable, Sendable {
    case unspecified
    case video
    case audio

    public var supportsProgramVideoMute: Bool {
        self == .video
    }
}

public enum ProgramInputDeviceBackgroundRemovalPolicy: String, Codable, Equatable, Sendable {
    case unspecified
    case enabled
    case disabled

    public var removesBackground: Bool {
        switch self {
        case .unspecified, .disabled:
            false
        case .enabled:
            true
        }
    }
}

public enum ProgramInputDeviceColorRangePolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case unspecified
    case videoRange
    case fullRange
}
