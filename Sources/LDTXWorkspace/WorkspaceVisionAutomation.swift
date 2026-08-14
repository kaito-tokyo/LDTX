// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct WorkspaceVisionDefinition: Codable, Equatable, Identifiable, Sendable {
  public static let minimumUpdateIntervalSeconds = 5.0
  public static let defaultSystemPrompt =
    "Answer as quickly as possible in short concise sentences. Describe the game or stream frame."
  public static let defaultUserPrompt = "Analyze this image."

  public var name: String
  public var source: WorkspaceVisionSource
  public var sourceCrop: WorkspaceVisionSourceCrop
  public var updateIntervalSeconds: Double? {
    didSet { updateIntervalSeconds = Self.normalizedUpdateInterval(updateIntervalSeconds) }
  }
  public var definition: WorkspaceVisionKind
  public var histogramGate: WorkspaceVisionHistogramGate?

  public var model: WorkspaceVisionModel {
    get { languageModelDefinition.model }
    set { updateLanguageModelDefinition { $0.model = newValue } }
  }
  public var systemPrompt: String {
    get { languageModelDefinition.systemPrompt }
    set { updateLanguageModelDefinition { $0.systemPrompt = newValue } }
  }
  public var userPrompt: String {
    get { languageModelDefinition.userPrompt }
    set { updateLanguageModelDefinition { $0.userPrompt = newValue } }
  }
  public var stopsAtNewline: Bool {
    get { languageModelDefinition.stopsAtNewline }
    set { updateLanguageModelDefinition { $0.stopsAtNewline = newValue } }
  }

  public init(
    id: String = "",
    name: String = "Vision",
    source: WorkspaceVisionSource = .landscapeProgramOutput,
    sourceCrop: WorkspaceVisionSourceCrop = .init(),
    model: WorkspaceVisionModel = .qwen3VL2BInstruct4Bit,
    systemPrompt: String = WorkspaceVisionDefinition.defaultSystemPrompt,
    userPrompt: String = WorkspaceVisionDefinition.defaultUserPrompt,
    updateIntervalSeconds: Double? = nil,
    stopsAtNewline: Bool = false,
    histogramGate: WorkspaceVisionHistogramGate? = nil
  ) {
    self.name = name
    self.source = source
    self.sourceCrop = sourceCrop
    self.updateIntervalSeconds = Self.normalizedUpdateInterval(updateIntervalSeconds)
    self.histogramGate = histogramGate
    self.definition = .visionLanguageModel(
      .init(
        model: model,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        stopsAtNewline: stopsAtNewline
      ))
  }

  public init(
    id: String = "",
    name: String = "Vision",
    source: WorkspaceVisionSource = .landscapeProgramOutput,
    model: WorkspaceVisionModel = .qwen3VL2BInstruct4Bit,
    prompt: String
  ) {
    self.init(id: id, name: name, source: source, model: model, systemPrompt: prompt)
  }

  private enum CodingKeys: String, CodingKey {
    case name, source, sourceCrop, model, systemPrompt, userPrompt, updateIntervalSeconds,
      stopsAtNewline, definition, prompt, histogramGate
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Vision"
    source =
      try values.decodeIfPresent(WorkspaceVisionSource.self, forKey: .source)
      ?? .landscapeProgramOutput
    sourceCrop =
      try values.decodeIfPresent(WorkspaceVisionSourceCrop.self, forKey: .sourceCrop) ?? .init()
    updateIntervalSeconds = Self.normalizedUpdateInterval(
      try values.decodeIfPresent(Double.self, forKey: .updateIntervalSeconds)
    )
    histogramGate = try values.decodeIfPresent(
      WorkspaceVisionHistogramGate.self, forKey: .histogramGate)
    if let decoded = try values.decodeIfPresent(WorkspaceVisionKind.self, forKey: .definition) {
      definition = decoded
    } else {
      let decodedSystemPrompt = try values.decodeIfPresent(String.self, forKey: .systemPrompt)
      let legacyPrompt = try values.decodeIfPresent(String.self, forKey: .prompt)
      definition = .visionLanguageModel(
        .init(
          model: try values.decodeIfPresent(WorkspaceVisionModel.self, forKey: .model)
            ?? .qwen3VL2BInstruct4Bit,
          systemPrompt: decodedSystemPrompt ?? legacyPrompt ?? Self.defaultSystemPrompt,
          userPrompt: try values.decodeIfPresent(String.self, forKey: .userPrompt)
            ?? Self.defaultUserPrompt,
          stopsAtNewline: try values.decodeIfPresent(Bool.self, forKey: .stopsAtNewline) ?? false
        ))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(name, forKey: .name)
    try values.encode(source, forKey: .source)
    try values.encode(sourceCrop, forKey: .sourceCrop)
    try values.encodeIfPresent(updateIntervalSeconds, forKey: .updateIntervalSeconds)
    try values.encodeIfPresent(histogramGate, forKey: .histogramGate)
    try values.encode(definition, forKey: .definition)
  }

  public var id: String { name }

  public static func normalizedUpdateInterval(_ interval: Double?) -> Double? {
    guard let interval, interval.isFinite, interval > 0 else { return nil }
    return max(interval, minimumUpdateIntervalSeconds)
  }

  private var languageModelDefinition: WorkspaceVisionLanguageModelDefinition {
    if case .visionLanguageModel(let value) = definition { return value }
    return .init()
  }

  private mutating func updateLanguageModelDefinition(
    _ update: (inout WorkspaceVisionLanguageModelDefinition) -> Void
  ) {
    var value = languageModelDefinition
    update(&value)
    definition = .visionLanguageModel(value)
  }
}

public struct WorkspaceVisionHistogramGate: Codable, Equatable, Sendable {
  public enum Channel: String, Codable, Equatable, Sendable {
    case hue
    case saturation
    case value
  }

  public var channel: Channel
  public var binCount: Int
  public var expectedPeakBin: Int
  public var minimumPeakRatio: Double
  public var region: WorkspaceVisionHistogramRegion

  public init(
    channel: Channel = .value,
    binCount: Int = 8,
    expectedPeakBin: Int = 0,
    minimumPeakRatio: Double = 0.8,
    region: WorkspaceVisionHistogramRegion = .init()
  ) {
    let validBinCount = min(max(binCount, 1), 256)
    self.channel = channel
    self.binCount = validBinCount
    self.expectedPeakBin = min(max(expectedPeakBin, 0), validBinCount - 1)
    self.minimumPeakRatio = min(max(minimumPeakRatio, 0), 1)
    self.region = .init(x: region.x, y: region.y, width: region.width, height: region.height)
  }
}

/// A normalized region within the Source Crop and resize result.
public struct WorkspaceVisionHistogramRegion: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
      self.x = 0
      self.y = 0
      self.width = 0
      self.height = 0
      return
    }
    let normalizedX = min(max(x, 0), 1)
    let normalizedY = min(max(y, 0), 1)
    self.x = normalizedX
    self.y = normalizedY
    self.width = min(max(width, 0), 1 - normalizedX)
    self.height = min(max(height, 0), 1 - normalizedY)
  }
}

public enum WorkspaceVisionSource: Codable, Equatable, Sendable {
  case landscapeProgramOutput
  case portraitProgramOutput
  case inputDevice(name: String)
}

public struct WorkspaceVisionSourceCrop: Codable, Equatable, Sendable {
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

public enum WorkspaceVisionKind: Codable, Equatable, Sendable {
  case visionLanguageModel(WorkspaceVisionLanguageModelDefinition)
  case opticalCharacterRecognition(WorkspaceVisionOCRDefinition)
}

public struct WorkspaceVisionLanguageModelDefinition: Codable, Equatable, Sendable {
  public var model: WorkspaceVisionModel
  public var systemPrompt: String
  public var userPrompt: String
  public var stopsAtNewline: Bool

  public init(
    model: WorkspaceVisionModel = .qwen3VL2BInstruct4Bit,
    systemPrompt: String = WorkspaceVisionDefinition.defaultSystemPrompt,
    userPrompt: String = WorkspaceVisionDefinition.defaultUserPrompt,
    stopsAtNewline: Bool = false
  ) {
    self.model = model
    self.systemPrompt = systemPrompt
    self.userPrompt = userPrompt
    self.stopsAtNewline = stopsAtNewline
  }
}

public struct WorkspaceVisionOCRDefinition: Codable, Equatable, Sendable {
  public enum RecognitionLevel: String, Codable, Equatable, Sendable {
    case fast
    case accurate
  }

  public var recognitionLevel: RecognitionLevel
  public var recognitionLanguages: [String]
  public var usesLanguageCorrection: Bool
  public var subsamplingRate: Int

  public init(
    recognitionLevel: RecognitionLevel = .accurate,
    recognitionLanguages: [String] = [],
    usesLanguageCorrection: Bool = true,
    subsamplingRate: Int = 2
  ) {
    self.recognitionLevel = recognitionLevel
    self.recognitionLanguages = recognitionLanguages
    self.usesLanguageCorrection = usesLanguageCorrection
    self.subsamplingRate = [1, 2, 4].contains(subsamplingRate) ? subsamplingRate : 2
  }
}

public struct WorkspaceVisionModel: Codable, Equatable, Sendable {
  public var repositoryID: String
  public var revision: String?
  public var expectedWeightSHA256: [String: String]

  public init(
    repositoryID: String,
    revision: String? = nil,
    expectedWeightSHA256: [String: String] = [:]
  ) {
    self.repositoryID = repositoryID
    self.revision = revision
    self.expectedWeightSHA256 = expectedWeightSHA256
  }

  private enum CodingKeys: String, CodingKey {
    case repositoryID, revision, expectedWeightSHA256
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    repositoryID = try values.decode(String.self, forKey: .repositoryID)
    revision = try values.decodeIfPresent(String.self, forKey: .revision)
    expectedWeightSHA256 =
      try values.decodeIfPresent([String: String].self, forKey: .expectedWeightSHA256) ?? [:]
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(repositoryID, forKey: .repositoryID)
    try values.encodeIfPresent(revision, forKey: .revision)
    if !expectedWeightSHA256.isEmpty {
      try values.encode(expectedWeightSHA256, forKey: .expectedWeightSHA256)
    }
  }

  /// Identifies both the model source and the integrity policy applied to it.
  public var cacheKey: String {
    let digests =
      expectedWeightSHA256
      .sorted { $0.key < $1.key }
      .map { "\($0.key)\u{0}\($0.value.lowercased())" }
      .joined(separator: "\u{0}")
    return "\(repositoryID)\u{0}\(revision ?? "main")\u{0}\(digests)"
  }

  public static let qwen3VL2BInstruct4Bit = WorkspaceVisionModel(
    repositoryID: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
    revision: "9c4f5209e57b31f4b9dfba735de3fb983739c9cc",
    expectedWeightSHA256: [
      "model.safetensors": "4750d95a2162829e127a94e83ac350d498d02070aab216c4687da48804a06ffb"
    ]
  )

  public static let qwen3VL4BInstruct4Bit = WorkspaceVisionModel(
    repositoryID: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit",
    revision: "552af30c9952c44f1e1a27c7c5810ded58e892bc",
    expectedWeightSHA256: [
      "model.safetensors": "5dfcf44a2af6329fcca64eff81569726eb8df42e43f8d2d4818d25502f7277bd"
    ]
  )

  public static func builtInModel(repositoryID: String) -> WorkspaceVisionModel? {
    switch repositoryID {
    case qwen3VL2BInstruct4Bit.repositoryID: qwen3VL2BInstruct4Bit
    case qwen3VL4BInstruct4Bit.repositoryID: qwen3VL4BInstruct4Bit
    default: nil
    }
  }
}
