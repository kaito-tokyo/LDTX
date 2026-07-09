// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

public enum BuiltInProgramDefinition: String, CaseIterable, Identifiable, Codable, Sendable {
    case inputCameraDevice
    case fillSolidColor
    case fillLinearGradient
    case fillRadialGradient
    case fillConicGradient
    case testPattern

    public static let allCases: [BuiltInProgramDefinition] = [
        .inputCameraDevice,
        .fillSolidColor,
        .fillLinearGradient,
        .fillRadialGradient,
        .fillConicGradient,
        .testPattern
    ]

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
    public var programVideoPTSInputKey: String?
    public var programAudioPTSInputKey: String?
    public var audioChannels: [ProgramAudioChannel]

    enum CodingKeys: String, CodingKey {
        case steps
        case programVideoPTSInputKey
        case programAudioPTSInputKey
        case audioChannels
    }

    public init(
        steps: [CompositeProgramStep] = [],
        programVideoPTSInputKey: String? = nil,
        programAudioPTSInputKey: String? = nil,
        audioChannels: [ProgramAudioChannel] = []
    ) {
        self.steps = steps
        self.audioChannels = audioChannels
        self.programVideoPTSInputKey =
            programVideoPTSInputKey.flatMap { resolvedInputCameraDeviceMappingKey(forStoredKey: $0) } ?? programVideoPTSInputKey
        self.programAudioPTSInputKey =
            programAudioPTSInputKey.flatMap { resolvedAudioChannelKey(forStoredKey: $0) } ?? programAudioPTSInputKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        steps = try container.decodeIfPresent([CompositeProgramStep].self, forKey: .steps) ?? []
        programVideoPTSInputKey = try container.decodeIfPresent(String.self, forKey: .programVideoPTSInputKey)
        programAudioPTSInputKey = try container.decodeIfPresent(String.self, forKey: .programAudioPTSInputKey)
        audioChannels = try container.decodeIfPresent([ProgramAudioChannel].self, forKey: .audioChannels) ?? []
        if let programVideoPTSInputKey {
            self.programVideoPTSInputKey = resolvedInputCameraDeviceMappingKey(forStoredKey: programVideoPTSInputKey)
        }
        if let programAudioPTSInputKey {
            self.programAudioPTSInputKey = resolvedAudioChannelKey(forStoredKey: programAudioPTSInputKey)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(steps, forKey: .steps)
        try container.encodeIfPresent(programVideoPTSInputKey, forKey: .programVideoPTSInputKey)
        try container.encodeIfPresent(programAudioPTSInputKey, forKey: .programAudioPTSInputKey)
        try container.encode(audioChannels, forKey: .audioChannels)
    }

    public func inputCameraDeviceMappingKey(for step: CompositeProgramStep) -> String {
        Self.stableKey(
            prefix: step.component.definition.rawValue,
            id: step.id
        )
    }

    public func inputCameraDeviceDisplayName(for step: CompositeProgramStep) -> String {
        return step.displayName ?? "\(step.component.definition.displayName) \(stepOrdinal(for: step))"
    }

    public func videoComponentDisplayName(for step: CompositeProgramStep) -> String {
        return step.displayName ?? "\(step.component.definition.displayName) \(stepOrdinal(for: step))"
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

    private func stepOrdinal(for step: CompositeProgramStep) -> Int {
        guard let index = steps.firstIndex(where: { $0.id == step.id }) else {
            return 1
        }
        let definition = step.component.definition
        return steps[...index].reduce(into: 0) { count, candidate in
            if candidate.component.definition == definition {
                count += 1
            }
        }
    }

    public func legacyInputCameraDeviceMappingKey(for step: CompositeProgramStep) -> String {
        "\(step.component.definition.rawValue) \(stepOrdinal(for: step))"
    }

    public func legacyAudioChannelKey(for channel: ProgramAudioChannel) -> String {
        audioChannels.legacyAudioChannelKey(for: channel)
    }

    public func resolvedInputCameraDeviceMappingKey(forStoredKey storedKey: String) -> String? {
        if steps.contains(where: { inputCameraDeviceMappingKey(for: $0) == storedKey }) {
            return storedKey
        }
        guard let step = steps.first(where: { legacyInputCameraDeviceMappingKey(for: $0) == storedKey }) else {
            return nil
        }
        return inputCameraDeviceMappingKey(for: step)
    }

    public func resolvedAudioChannelKey(forStoredKey storedKey: String) -> String? {
        audioChannels.resolvedAudioChannelKey(forStoredKey: storedKey)
    }

    fileprivate static func stableKey(prefix: String, id: UUID) -> String {
        "\(prefix):\(id.uuidString.lowercased())"
    }
}

public struct ProgramArguments: Codable, Equatable, Sendable {
    public static let minimumAudioChannelGainDecibels = -80.0
    public static let maximumAudioChannelGainDecibels = 20.0

    public static let minimumAudioChannelGain = pow(10.0, minimumAudioChannelGainDecibels / 20.0)
    public static let maximumAudioChannelGain = pow(10.0, maximumAudioChannelGainDecibels / 20.0)

    public var audioChannelGainsByName: [String: Double]

    enum CodingKeys: String, CodingKey {
        case audioChannelGainsByName
    }

    public init(audioChannelGainsByName: [String: Double] = [:]) {
        self.audioChannelGainsByName = audioChannelGainsByName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioChannelGainsByName =
            try container.decodeIfPresent([String: Double].self, forKey: .audioChannelGainsByName) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(audioChannelGainsByName, forKey: .audioChannelGainsByName)
    }

    public func audioChannelGain(for channel: ProgramAudioChannel, in composite: CompositeProgramDefinition) -> Double {
        audioChannelGain(for: channel, in: composite.audioChannels)
    }

    public func audioChannelGain(for channel: ProgramAudioChannel, in audioChannels: [ProgramAudioChannel]) -> Double {
        let key = resolvedAudioChannelStorageKey(for: channel, in: audioChannels)
        return Self.clampedAudioChannelGain(audioChannelGainsByName[key] ?? 1.0)
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
        audioChannelGainsByName.removeValue(forKey: audioChannels.legacyAudioChannelKey(for: channel))
        audioChannelGainsByName[key] = Self.clampedAudioChannelGain(gain)
    }

    public func audioChannelGainsByKey(for composite: CompositeProgramDefinition) -> [String: Double] {
        audioChannelGainsByKey(for: composite.audioChannels)
    }

    public func audioChannelGainsByKey(for audioChannels: [ProgramAudioChannel]) -> [String: Double] {
        var gainsByKey: [String: Double] = [:]
        for channel in audioChannels {
            let key = audioChannels.audioChannelKey(for: channel)
            let storedKey = resolvedAudioChannelStorageKey(for: channel, in: audioChannels)
            gainsByKey[key] = Self.clampedAudioChannelGain(audioChannelGainsByName[storedKey] ?? 1.0)
        }
        return gainsByKey
    }

    private func resolvedAudioChannelStorageKey(
        for channel: ProgramAudioChannel,
        in composite: CompositeProgramDefinition
    ) -> String {
        resolvedAudioChannelStorageKey(for: channel, in: composite.audioChannels)
    }

    private func resolvedAudioChannelStorageKey(
        for channel: ProgramAudioChannel,
        in audioChannels: [ProgramAudioChannel]
    ) -> String {
        let key = audioChannels.audioChannelKey(for: channel)
        if audioChannelGainsByName[key] != nil {
            return key
        }
        let legacyKey = audioChannels.legacyAudioChannelKey(for: channel)
        if audioChannelGainsByName[legacyKey] != nil {
            return legacyKey
        }
        return key
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
        CompositeProgramDefinition.stableKey(
            prefix: channel.component.definition.rawValue,
            id: channel.id
        )
    }

    func audioChannelDisplayName(for channel: ProgramAudioChannel) -> String {
        "\(channel.component.definition.displayName) \(audioChannelOrdinal(for: channel))"
    }

    func legacyAudioChannelKey(for channel: ProgramAudioChannel) -> String {
        "\(channel.component.definition.rawValue) \(audioChannelOrdinal(for: channel))"
    }

    func resolvedAudioChannelKey(forStoredKey storedKey: String) -> String? {
        if contains(where: { audioChannelKey(for: $0) == storedKey }) {
            return storedKey
        }
        guard let channel = first(where: { legacyAudioChannelKey(for: $0) == storedKey }) else {
            return nil
        }
        return audioChannelKey(for: channel)
    }

    private func audioChannelOrdinal(for channel: ProgramAudioChannel) -> Int {
        guard let index = firstIndex(where: { $0.id == channel.id }) else {
            return 1
        }
        let definition = channel.component.definition
        return self[...index].reduce(into: 0) { count, candidate in
            if candidate.component.definition == definition {
                count += 1
            }
        }
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
                    id: stableWorkspaceAudioChannelID(for: inputDevice.id),
                    component: .inputAudioDevice(
                        InputAudioDeviceComponent(inputDeviceID: inputDevice.id)
                    )
                )
            )
        }

        return resolvedAudioChannels
    }

    private func stableWorkspaceAudioChannelID(for inputDeviceID: String) -> UUID {
        if let existingUUID = UUID(uuidString: inputDeviceID) {
            return existingUUID
        }

        let digest = SHA256.hash(data: Data("workspace-audio:\(inputDeviceID)".utf8))
        var bytes: [UInt8] = Swift.Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public struct CompositeProgramStep: Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String?
    public var component: ProgramComponent

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case component
    }

    public init(
        id: UUID = UUID(),
        displayName: String? = nil,
        component: ProgramComponent = .inputCameraDevice(InputDeviceComponent())
    ) {
        self.id = id
        self.displayName = displayName
        self.component = component
    }

    public init(id: UUID = UUID(), component: ProgramComponent) {
        self.init(id: id, displayName: nil, component: component)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        component = try container.decodeIfPresent(ProgramComponent.self, forKey: .component) ??
            .inputCameraDevice(InputDeviceComponent())
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(component, forKey: .component)
    }

    public static func == (lhs: CompositeProgramStep, rhs: CompositeProgramStep) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName && lhs.component == rhs.component
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
    public let id: UUID
    public var component: ProgramAudioChannelComponent

    enum CodingKeys: String, CodingKey {
        case id
        case component
    }

    public init(
        id: UUID = UUID(),
        component: ProgramAudioChannelComponent = .inputAudioDevice(InputAudioDeviceComponent())
    ) {
        self.id = id
        self.component = component
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        component = try container.decodeIfPresent(ProgramAudioChannelComponent.self, forKey: .component) ??
            .inputAudioDevice(InputAudioDeviceComponent())
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(component, forKey: .component)
    }

    public static func == (lhs: ProgramAudioChannel, rhs: ProgramAudioChannel) -> Bool {
        lhs.id == rhs.id && lhs.component == rhs.component
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
    case inputCameraDevice(InputDeviceComponent)
    case testPattern

    enum CodingKeys: String, CodingKey {
        case id
        case parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let definition = try container.decode(BuiltInProgramDefinition.self, forKey: .id)
        switch definition {
        case .fillSolidColor:
            self = .fillSolidColor(try container.decode(FillSolidColorComponent.self, forKey: .parameters))
        case .fillLinearGradient:
            self = .fillLinearGradient(try container.decode(FillLinearGradientComponent.self, forKey: .parameters))
        case .fillRadialGradient:
            self = .fillRadialGradient(try container.decode(FillRadialGradientComponent.self, forKey: .parameters))
        case .fillConicGradient:
            self = .fillConicGradient(try container.decode(FillConicGradientComponent.self, forKey: .parameters))
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
        case let .inputCameraDevice(payload):
            try payload.encodeComponentParameters(to: encoder)
        case .testPattern:
            try EmptyProgramComponentParameters().encodeComponentParameters(to: encoder)
        }
    }

    public static func defaultComponent(for definition: BuiltInProgramDefinition) -> ProgramComponent {
        switch definition {
        case .fillSolidColor:
            .fillSolidColor(FillSolidColorComponent())
        case .fillLinearGradient:
            .fillLinearGradient(FillLinearGradientComponent())
        case .fillRadialGradient:
            .fillRadialGradient(FillRadialGradientComponent())
        case .fillConicGradient:
            .fillConicGradient(FillConicGradientComponent())
        case .inputCameraDevice:
            .inputCameraDevice(InputDeviceComponent())
        case .testPattern:
            .testPattern
        }
    }

    public var definition: BuiltInProgramDefinition {
        switch self {
        case .fillSolidColor:
            .fillSolidColor
        case .fillLinearGradient:
            .fillLinearGradient
        case .fillRadialGradient:
            .fillRadialGradient
        case .fillConicGradient:
            .fillConicGradient
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

public struct InputDeviceComponent: ProgramComponentParameters {
    public var inputDeviceID: String?
    public var sourceCropTop: Float
    public var sourceCropRight: Float
    public var sourceCropBottom: Float
    public var sourceCropLeft: Float
    public var destinationX: Float
    public var destinationY: Float
    public var destinationScale: Float

    enum CodingKeys: String, CodingKey {
        case inputDeviceID
        case sourceCropTop
        case sourceCropRight
        case sourceCropBottom
        case sourceCropLeft
        case destinationX
        case destinationY
        case destinationScale
    }

    public init(
        inputDeviceID: String? = nil,
        sourceCropTop: Float = 0,
        sourceCropRight: Float = 0,
        sourceCropBottom: Float = 0,
        sourceCropLeft: Float = 0,
        destinationX: Float = 0,
        destinationY: Float = 0,
        destinationScale: Float = 1
    ) {
        self.inputDeviceID = inputDeviceID
        self.sourceCropTop = sourceCropTop
        self.sourceCropRight = sourceCropRight
        self.sourceCropBottom = sourceCropBottom
        self.sourceCropLeft = sourceCropLeft
        self.destinationX = destinationX
        self.destinationY = destinationY
        self.destinationScale = destinationScale
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

    enum CodingKeys: String, CodingKey {
        case name
        case canvasWidth
        case canvasHeight
        case frameRateNumerator
        case frameRateDenominator
        case videoComponents
        case audioChannels
        case programVideoPTSInputKey
        case programAudioPTSInputKey
        case inputDevices
        case composite
    }

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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        canvasWidth = try container.decode(Int.self, forKey: .canvasWidth)
        canvasHeight = try container.decode(Int.self, forKey: .canvasHeight)
        frameRateNumerator = try container.decode(Int.self, forKey: .frameRateNumerator)
        frameRateDenominator = try container.decode(Int.self, forKey: .frameRateDenominator)
        inputDevices =
            try container.decodeIfPresent([ProgramInputDeviceRecord].self, forKey: .inputDevices) ?? []
        if let legacyComposite = try container.decodeIfPresent(CompositeProgramDefinition.self, forKey: .composite) {
            composite = legacyComposite
        } else {
            composite = CompositeProgramDefinition(
                steps: try container.decodeIfPresent([CompositeProgramStep].self, forKey: .videoComponents) ?? [],
                programVideoPTSInputKey: try container.decodeIfPresent(String.self, forKey: .programVideoPTSInputKey),
                programAudioPTSInputKey: try container.decodeIfPresent(String.self, forKey: .programAudioPTSInputKey),
                audioChannels: try container.decodeIfPresent([ProgramAudioChannel].self, forKey: .audioChannels) ?? []
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(canvasWidth, forKey: .canvasWidth)
        try container.encode(canvasHeight, forKey: .canvasHeight)
        try container.encode(frameRateNumerator, forKey: .frameRateNumerator)
        try container.encode(frameRateDenominator, forKey: .frameRateDenominator)
        try container.encode(composite.steps, forKey: .videoComponents)
        try container.encode(composite.audioChannels, forKey: .audioChannels)
        try container.encodeIfPresent(composite.programVideoPTSInputKey, forKey: .programVideoPTSInputKey)
        try container.encodeIfPresent(composite.programAudioPTSInputKey, forKey: .programAudioPTSInputKey)
        try container.encode(inputDevices, forKey: .inputDevices)
    }
}

public struct ProgramInputDeviceRecord: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: ProgramInputDeviceKind
    public var physicalDeviceID: String?
    public var sideTrackRecordingPolicy: ProgramSideTrackRecordingPolicy
    public var backgroundRemovalPolicy: ProgramInputDeviceBackgroundRemovalPolicy
    public var colorRangePolicy: ProgramInputDeviceColorRangePolicy
    public var captureWidthOverride: Int?
    public var captureHeightOverride: Int?
    public var captureFrameRateOverride: Int?

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: ProgramInputDeviceKind,
        physicalDeviceID: String? = nil,
        sideTrackRecordingPolicy: ProgramSideTrackRecordingPolicy = .unspecified,
        backgroundRemovalPolicy: ProgramInputDeviceBackgroundRemovalPolicy = .unspecified,
        colorRangePolicy: ProgramInputDeviceColorRangePolicy = .unspecified,
        captureWidthOverride: Int? = nil,
        captureHeightOverride: Int? = nil,
        captureFrameRateOverride: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.physicalDeviceID = physicalDeviceID
        self.sideTrackRecordingPolicy = sideTrackRecordingPolicy
        self.backgroundRemovalPolicy = backgroundRemovalPolicy
        self.colorRangePolicy = colorRangePolicy
        self.captureWidthOverride = captureWidthOverride
        self.captureHeightOverride = captureHeightOverride
        self.captureFrameRateOverride = captureFrameRateOverride
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case physicalDeviceID
        case sideTrackRecordingPolicy
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
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        physicalDeviceID = try container.decodeIfPresent(String.self, forKey: .physicalDeviceID)
        sideTrackRecordingPolicy =
            try container.decodeIfPresent(
                ProgramSideTrackRecordingPolicy.self,
                forKey: .sideTrackRecordingPolicy
            ) ?? .unspecified
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

    public var isMuted: Bool {
        sideTrackRecordingPolicy == .disabled
    }

    public mutating func setMuted(_ isMuted: Bool) {
        sideTrackRecordingPolicy = isMuted ? .disabled : .enabled
    }

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
}

public enum ProgramSideTrackRecordingPolicy: String, Codable, Equatable, Sendable {
    case unspecified
    case enabled
    case disabled

    public var recordsSideTrack: Bool {
        switch self {
        case .unspecified, .enabled:
            true
        case .disabled:
            false
        }
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

public struct SavedProgramArgumentsRecord: Codable, Equatable, Sendable {
    public var name: String
    public var arguments: ProgramArguments

    public init(name: String, arguments: ProgramArguments = ProgramArguments()) {
        self.name = name
        self.arguments = arguments
    }
}
