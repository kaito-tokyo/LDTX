// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct WorkspaceVisionDefinition: Codable, Equatable, Identifiable, Sendable {
    public static let defaultSystemPrompt =
        "Answer as quickly as possible in short concise sentences. Describe the game or stream frame."
    public static let defaultUserPrompt = "Analyze this image."

    public var name: String
    public var source: WorkspaceVisionSource
    public var model: WorkspaceVisionModel
    public var systemPrompt: String
    public var userPrompt: String
    public var updateIntervalSeconds: Double?
    public var stopsAtNewline: Bool
    public var postActionAutomationName: String?

    public init(
        id: String = "",
        name: String = "Vision",
        source: WorkspaceVisionSource = .currentProgramOutput,
        model: WorkspaceVisionModel = .qwen3VL2BInstruct4Bit,
        systemPrompt: String = WorkspaceVisionDefinition.defaultSystemPrompt,
        userPrompt: String = WorkspaceVisionDefinition.defaultUserPrompt,
        updateIntervalSeconds: Double? = nil,
        stopsAtNewline: Bool = false,
        postActionAutomationName: String? = nil
    ) {
        self.name = name
        self.source = source
        self.model = model
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.updateIntervalSeconds = updateIntervalSeconds
        self.stopsAtNewline = stopsAtNewline
        self.postActionAutomationName = postActionAutomationName
    }

    public init(
        id: String = "",
        name: String = "Vision",
        source: WorkspaceVisionSource = .currentProgramOutput,
        model: WorkspaceVisionModel = .qwen3VL2BInstruct4Bit,
        prompt: String
    ) {
        self.init(id: id, name: name, source: source, model: model, systemPrompt: prompt)
    }

    private enum CodingKeys: String, CodingKey {
        case name, source, model, systemPrompt, userPrompt, updateIntervalSeconds, stopsAtNewline
        case postActionAutomationName, prompt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Vision"
        source = try values.decodeIfPresent(WorkspaceVisionSource.self, forKey: .source) ?? .currentProgramOutput
        model = try values.decodeIfPresent(WorkspaceVisionModel.self, forKey: .model) ?? .qwen3VL2BInstruct4Bit
        let decodedSystemPrompt = try values.decodeIfPresent(String.self, forKey: .systemPrompt)
        let legacyPrompt = try values.decodeIfPresent(String.self, forKey: .prompt)
        systemPrompt = decodedSystemPrompt ?? legacyPrompt ?? Self.defaultSystemPrompt
        userPrompt = try values.decodeIfPresent(String.self, forKey: .userPrompt) ?? Self.defaultUserPrompt
        updateIntervalSeconds = try values.decodeIfPresent(Double.self, forKey: .updateIntervalSeconds)
        stopsAtNewline = try values.decodeIfPresent(Bool.self, forKey: .stopsAtNewline) ?? false
        postActionAutomationName = try values.decodeIfPresent(String.self, forKey: .postActionAutomationName)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(source, forKey: .source)
        try values.encode(model, forKey: .model)
        try values.encode(systemPrompt, forKey: .systemPrompt)
        try values.encode(userPrompt, forKey: .userPrompt)
        try values.encodeIfPresent(updateIntervalSeconds, forKey: .updateIntervalSeconds)
        try values.encode(stopsAtNewline, forKey: .stopsAtNewline)
        try values.encodeIfPresent(postActionAutomationName, forKey: .postActionAutomationName)
    }

    public var id: String { name }
}

public enum WorkspaceVisionSource: Codable, Equatable, Sendable {
    case currentProgramOutput
    case inputDevice(name: String)
}

public struct WorkspaceVisionModel: Codable, Equatable, Sendable {
    public var repositoryID: String
    public var revision: String?

    public init(repositoryID: String, revision: String? = nil) {
        self.repositoryID = repositoryID
        self.revision = revision
    }

    public static let qwen3VL2BInstruct4Bit = WorkspaceVisionModel(
        repositoryID: "mlx-community/Qwen3-VL-2B-Instruct-4bit"
    )

    public static let qwen3VL4BInstruct4Bit = WorkspaceVisionModel(
        repositoryID: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit"
    )
}

public struct WorkspaceAutomationDefinition: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var isEnabled: Bool
    public var trigger: WorkspaceAutomationTrigger
    public var actions: [WorkspaceAutomationAction]

    public init(
        id: String = "",
        name: String = "Automation",
        isEnabled: Bool = true,
        trigger: WorkspaceAutomationTrigger = .manual,
        actions: [WorkspaceAutomationAction] = []
    ) {
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.actions = actions
    }

    public var id: String { name }
}

public enum WorkspaceAutomationTrigger: Codable, Equatable, Sendable {
    case manual
    case interval(seconds: Double)
}

public enum WorkspaceAutomationAction: Codable, Equatable, Sendable {
    case analyzeVision(visionName: String)
    case selectInputDevice(inputDeviceName: String)

    public static func makeAnalyzeVision(visionName: String) -> Self {
        .analyzeVision(visionName: visionName)
    }

    public static func makeSelectInputDevice(inputDeviceName: String) -> Self {
        .selectInputDevice(inputDeviceName: inputDeviceName)
    }
}
