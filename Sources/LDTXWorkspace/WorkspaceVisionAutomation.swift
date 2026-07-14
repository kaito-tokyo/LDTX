// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct WorkspaceVisionDefinition: Codable, Equatable, Identifiable, Sendable {
    public static let defaultSystemPrompt =
        "Answer as quickly as possible in short concise sentences. Describe the game or stream frame."
    public static let defaultUserPrompt = "Analyze this image."

    public var id: String
    public var name: String
    public var source: WorkspaceVisionSource
    public var model: WorkspaceVisionModel
    public var systemPrompt: String
    public var userPrompt: String
    public var updateIntervalSeconds: Double?
    public var stopsAtNewline: Bool
    public var postActionAutomationID: String?

    public init(
        id: String = UUID().uuidString,
        name: String = "Vision",
        source: WorkspaceVisionSource = .currentProgramOutput,
        model: WorkspaceVisionModel = .qwen3VL2BInstruct4Bit,
        systemPrompt: String = WorkspaceVisionDefinition.defaultSystemPrompt,
        userPrompt: String = WorkspaceVisionDefinition.defaultUserPrompt,
        updateIntervalSeconds: Double? = nil,
        stopsAtNewline: Bool = false,
        postActionAutomationID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.model = model
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.updateIntervalSeconds = updateIntervalSeconds
        self.stopsAtNewline = stopsAtNewline
        self.postActionAutomationID = postActionAutomationID
    }

    public init(
        id: String = UUID().uuidString,
        name: String = "Vision",
        source: WorkspaceVisionSource = .currentProgramOutput,
        model: WorkspaceVisionModel = .qwen3VL2BInstruct4Bit,
        prompt: String
    ) {
        self.init(id: id, name: name, source: source, model: model, systemPrompt: prompt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, source, model, systemPrompt, userPrompt, updateIntervalSeconds, stopsAtNewline
        case postActionAutomationID, prompt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Vision"
        source = try values.decodeIfPresent(WorkspaceVisionSource.self, forKey: .source) ?? .currentProgramOutput
        model = try values.decodeIfPresent(WorkspaceVisionModel.self, forKey: .model) ?? .qwen3VL2BInstruct4Bit
        let decodedSystemPrompt = try values.decodeIfPresent(String.self, forKey: .systemPrompt)
        let legacyPrompt = try values.decodeIfPresent(String.self, forKey: .prompt)
        systemPrompt = decodedSystemPrompt ?? legacyPrompt ?? Self.defaultSystemPrompt
        userPrompt = try values.decodeIfPresent(String.self, forKey: .userPrompt) ?? Self.defaultUserPrompt
        updateIntervalSeconds = try values.decodeIfPresent(Double.self, forKey: .updateIntervalSeconds)
        stopsAtNewline = try values.decodeIfPresent(Bool.self, forKey: .stopsAtNewline) ?? false
        postActionAutomationID = try values.decodeIfPresent(String.self, forKey: .postActionAutomationID)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(source, forKey: .source)
        try values.encode(model, forKey: .model)
        try values.encode(systemPrompt, forKey: .systemPrompt)
        try values.encode(userPrompt, forKey: .userPrompt)
        try values.encodeIfPresent(updateIntervalSeconds, forKey: .updateIntervalSeconds)
        try values.encode(stopsAtNewline, forKey: .stopsAtNewline)
        try values.encodeIfPresent(postActionAutomationID, forKey: .postActionAutomationID)
    }
}

public enum WorkspaceVisionSource: Codable, Equatable, Sendable {
    case currentProgramOutput
    case inputDevice(id: String)
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
    public var id: String
    public var name: String
    public var isEnabled: Bool
    public var trigger: WorkspaceAutomationTrigger
    public var actions: [WorkspaceAutomationAction]

    public init(
        id: String = UUID().uuidString,
        name: String = "Automation",
        isEnabled: Bool = true,
        trigger: WorkspaceAutomationTrigger = .manual,
        actions: [WorkspaceAutomationAction] = []
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.actions = actions
    }
}

public enum WorkspaceAutomationTrigger: Codable, Equatable, Sendable {
    case manual
    case interval(seconds: Double)
}

public enum WorkspaceAutomationAction: Codable, Equatable, Identifiable, Sendable {
    case analyzeVision(id: String, visionID: String)
    case selectInputDevice(id: String, inputDeviceID: String)

    public var id: String {
        switch self {
        case let .analyzeVision(id, _), let .selectInputDevice(id, _):
            id
        }
    }

    public static func makeAnalyzeVision(visionID: String) -> Self {
        .analyzeVision(id: UUID().uuidString, visionID: visionID)
    }

    public static func makeSelectInputDevice(inputDeviceID: String) -> Self {
        .selectInputDevice(id: UUID().uuidString, inputDeviceID: inputDeviceID)
    }
}
