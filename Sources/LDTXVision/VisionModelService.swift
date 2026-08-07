// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreImage
import Foundation
import LDTXTaskQueue
import LDTXWorkspace
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

public enum VisionModelServiceError: Error, LocalizedError {
  case modelNotDownloaded(String)
  case modelNotLoaded(String)

  public var errorDescription: String? {
    switch self {
    case .modelNotDownloaded(let id):
      "Vision model is not downloaded. Download it from Settings: \(id)"
    case .modelNotLoaded(let id):
      "Vision model is not loaded: \(id)"
    }
  }
}

public struct VisionAnalysis: Equatable, Sendable {
  public var output: String
  public var elapsedSeconds: TimeInterval
  public var promptTokenCount: Int?
  public var generationTokenCount: Int?
  public var promptTokensPerSecond: Double?
  public var tokensPerSecond: Double?
  public var memory: VisionMemoryMetrics

  public init(
    output: String,
    elapsedSeconds: TimeInterval,
    promptTokenCount: Int? = nil,
    generationTokenCount: Int? = nil,
    promptTokensPerSecond: Double? = nil,
    tokensPerSecond: Double? = nil,
    memory: VisionMemoryMetrics = .zero
  ) {
    self.output = output
    self.elapsedSeconds = elapsedSeconds
    self.promptTokenCount = promptTokenCount
    self.generationTokenCount = generationTokenCount
    self.promptTokensPerSecond = promptTokensPerSecond
    self.tokensPerSecond = tokensPerSecond
    self.memory = memory
  }
}

public struct VisionMemoryMetrics: Equatable, Sendable {
  public var activeBytes: Int
  public var cachedBytes: Int
  public var peakActiveBytes: Int
  public var poolGrowthBytes: Int
  public var cacheLimitBytes: Int

  public static let zero = VisionMemoryMetrics(
    activeBytes: 0,
    cachedBytes: 0,
    peakActiveBytes: 0,
    poolGrowthBytes: 0,
    cacheLimitBytes: 0
  )

  public var isPoolStable: Bool { poolGrowthBytes <= 1_048_576 }
}

public actor VisionModelService {
  private var containers: [String: ModelContainer] = [:]
  private var prefixCaches: [String: VisionPrefixCache] = [:]
  private var loadStartedKeys: Set<String> = []
  private var verifiedModelDirectories: [String: URL] = [:]
  private var modelDirectoryTasks: [String: (id: UUID, task: Task<URL?, Never>)] = [:]
  private let modelDirectoryResolver: @Sendable (WorkspaceVisionModel) -> URL?
  private var inferenceIsRunning = false
  private var inferenceWaiters: [CheckedContinuation<Void, Never>] = []

  public init() {
    modelDirectoryResolver = { VisionModelCache.snapshotDirectory(for: $0) }
  }

  init(modelDirectoryResolver: @escaping @Sendable (WorkspaceVisionModel) -> URL?) {
    self.modelDirectoryResolver = modelDirectoryResolver
  }

  public func load(model: WorkspaceVisionModel) async throws {
    let cacheKey = model.cacheKey
    if containers[cacheKey] != nil {
      return
    }
    guard loadStartedKeys.insert(cacheKey).inserted else {
      return
    }
    defer {
      if containers[cacheKey] == nil {
        loadStartedKeys.remove(cacheKey)
      }
    }
    guard let modelDirectory = await modelDirectory(for: model, revalidatesCachedResult: true) else {
      throw VisionModelServiceError.modelNotDownloaded(model.repositoryID)
    }
    let configuration = ModelConfiguration(
      directory: modelDirectory,
      defaultPrompt: "Describe the image in English",
      extraEOSTokens: ["<|im_end|>"]
    )
    let context = try await VLMModelFactory.shared._load(
      configuration: configuration.resolved(
        modelDirectory: modelDirectory,
        tokenizerDirectory: modelDirectory
      ),
      tokenizerLoader: VisionTokenizerLoader()
    )
    containers[cacheKey] = VLMModelFactory.shared._wrap(context)
    prefixCaches[cacheKey] = nil
  }

  public func removeAllModels() {
    containers.removeAll()
    prefixCaches.removeAll()
    verifiedModelDirectories.removeAll()
    modelDirectoryTasks.values.forEach { $0.task.cancel() }
    modelDirectoryTasks.removeAll()
  }

  public func analyze(
    image: CIImage,
    systemPrompt: String,
    userPrompt: String,
    stopsAtNewline: Bool,
    model: WorkspaceVisionModel,
    maxTokens: Int = 24,
    stopToken: StopToken = .neverStopped
  ) async throws -> VisionAnalysis {
    try stopToken.check()
    await acquireInferenceSlot()
    defer { releaseInferenceSlot() }
    try Task.checkCancellation()
    try stopToken.check()
    guard let container = containers[model.cacheKey] else {
      throw VisionModelServiceError.modelNotLoaded(model.repositoryID)
    }
    let startedAt = Date()
    let memoryBefore = Memory.snapshot()
    Memory.peakMemory = 0
    let cachedPrefix = prefixCaches[model.cacheKey].flatMap {
      $0.systemPrompt == systemPrompt ? $0 : nil
    }
    let operation = try await container.perform(
      nonSendable: VisionGenerationInput(
        image: image,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        stopsAtNewline: stopsAtNewline,
        maxTokens: maxTokens,
        cachedPrefix: cachedPrefix
      )
    ) { context, request in
      try stopToken.check()
      let fullInput = try await context.processor.prepare(
        input: UserInput(
          chat: [
            .system(request.systemPrompt),
            .user(request.userPrompt, images: [.ciImage(request.image)]),
          ],
          processing: .init(
            resize: CGSize(
              width: VisionFramePool.width,
              height: VisionFramePool.height
            )))
      )
      let fullTokens = fullInput.text.tokens.asArray(Int.self)
      try stopToken.check()
      let templateMessages = Qwen3VLMessageGenerator().generate(messages: [
        .system(request.systemPrompt),
        .user(request.userPrompt, images: [.ciImage(request.image)]),
      ])
      let templateTokens = try context.tokenizer.applyChatTemplate(messages: templateMessages)
      let imagePaddingToken = context.tokenizer.convertTokenToId("<|image_pad|>")
      let prefixEnd = imagePaddingToken.flatMap { templateTokens.firstIndex(of: $0) } ?? 0
      let prefixTokens = Array(templateTokens[..<prefixEnd])

      let prefix: VisionPrefixCache?
      if let cached = request.cachedPrefix,
        Self.hasPrefix(fullTokens, prefixTokens: cached.tokens)
      {
        prefix = cached
      } else if Self.hasPrefix(fullTokens, prefixTokens: prefixTokens), !prefixTokens.isEmpty {
        let cache = context.model.newCache(parameters: nil)
        _ = try TokenIterator(
          input: LMInput(tokens: MLXArray(prefixTokens).expandedDimensions(axis: 0)),
          model: context.model,
          cache: cache,
          parameters: GenerateParameters(maxTokens: 1, temperature: 0)
        )
        eval(cache)
        prefix = VisionPrefixCache(
          systemPrompt: request.systemPrompt,
          tokens: prefixTokens,
          cache: VisionKVCacheBox(cache)
        )
      } else {
        prefix = nil
      }

      let generationInput: LMInput
      let generationCache: [KVCache]?
      if let prefix {
        let prefixCount = prefix.tokens.count
        generationInput = LMInput(
          text: fullInput.text[0..., prefixCount...],
          image: fullInput.image,
          video: fullInput.video,
          audio: fullInput.audio
        )
        generationCache = prefix.cache.value.map { $0.copy() }
      } else {
        generationInput = fullInput
        generationCache = nil
      }

      var generationContext = context
      if request.stopsAtNewline {
        generationContext.configuration.stopStrings =
          generationContext.configuration.effectiveStopStrings.union(["\n"])
      }
      let stream = try MLXLMCommon.generate(
        input: generationInput,
        cache: generationCache,
        parameters: GenerateParameters(maxTokens: request.maxTokens, temperature: 0),
        context: generationContext
      )
      var output = ""
      var completionInfo: GenerateCompletionInfo?
      for await generation in stream {
        try Task.checkCancellation()
        try stopToken.check()
        switch generation {
        case .chunk(let text): output += text
        case .info(let info): completionInfo = info
        case .toolCall: break
        }
      }
      try stopToken.check()
      return VisionGenerationOutput(
        output: output,
        fullPromptTokenCount: fullTokens.count,
        completionInfo: completionInfo,
        prefix: prefix
      )
    }
    prefixCaches[model.cacheKey] = operation.prefix
    let memoryAfter = Memory.snapshot()
    return VisionAnalysis(
      output: operation.output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
      elapsedSeconds: Date().timeIntervalSince(startedAt),
      promptTokenCount: operation.fullPromptTokenCount,
      generationTokenCount: operation.completionInfo?.generationTokenCount,
      promptTokensPerSecond: operation.completionInfo?.promptTokensPerSecond,
      tokensPerSecond: operation.completionInfo?.tokensPerSecond,
      memory: memoryMetrics(before: memoryBefore, after: memoryAfter)
    )
  }

  public func isLoaded(model: WorkspaceVisionModel) -> Bool {
    containers[model.cacheKey] != nil
  }

  public func isDownloaded(model: WorkspaceVisionModel) async -> Bool {
    await modelDirectory(for: model) != nil
  }

  func isDownloaded(
    model: WorkspaceVisionModel,
    revalidatesCachedResult: Bool
  ) async -> Bool {
    await modelDirectory(
      for: model,
      revalidatesCachedResult: revalidatesCachedResult
    ) != nil
  }

  private func modelDirectory(
    for model: WorkspaceVisionModel,
    revalidatesCachedResult: Bool = false
  ) async -> URL? {
    let key = model.cacheKey
    if !revalidatesCachedResult {
      if let directory = verifiedModelDirectories[key] { return directory }
      if let pending = modelDirectoryTasks[key] { return await pending.task.value }
    }
    let id = UUID()
    let resolver = modelDirectoryResolver
    let task = Task.detached(priority: .utility) {
      resolver(model)
    }
    modelDirectoryTasks[key] = (id, task)
    let directory = await task.value
    guard modelDirectoryTasks[key]?.id == id else { return nil }
    modelDirectoryTasks[key] = nil
    if let directory { verifiedModelDirectories[key] = directory }
    return directory
  }

  private nonisolated static func hasPrefix(_ tokens: [Int], prefixTokens: [Int]) -> Bool {
    tokens.count >= prefixTokens.count
      && tokens.prefix(prefixTokens.count).elementsEqual(prefixTokens)
  }

  private func acquireInferenceSlot() async {
    if !inferenceIsRunning {
      inferenceIsRunning = true
      return
    }
    await withCheckedContinuation { continuation in
      inferenceWaiters.append(continuation)
    }
  }

  private func releaseInferenceSlot() {
    if inferenceWaiters.isEmpty {
      inferenceIsRunning = false
    } else {
      inferenceWaiters.removeFirst().resume()
    }
  }

  private func memoryMetrics(before: Memory.Snapshot, after: Memory.Snapshot) -> VisionMemoryMetrics
  {
    let beforeAllocated = before.activeMemory + before.cacheMemory
    let afterAllocated = after.activeMemory + after.cacheMemory
    return VisionMemoryMetrics(
      activeBytes: after.activeMemory,
      cachedBytes: after.cacheMemory,
      peakActiveBytes: after.peakMemory,
      poolGrowthBytes: max(0, afterAllocated - beforeAllocated),
      cacheLimitBytes: Memory.cacheLimit
    )
  }
}

private struct VisionGenerationInput {
  let image: CIImage
  let systemPrompt: String
  let userPrompt: String
  let stopsAtNewline: Bool
  let maxTokens: Int
  let cachedPrefix: VisionPrefixCache?
}

private struct VisionGenerationOutput: @unchecked Sendable {
  let output: String
  let fullPromptTokenCount: Int
  let completionInfo: GenerateCompletionInfo?
  let prefix: VisionPrefixCache?
}

private struct VisionPrefixCache: @unchecked Sendable {
  let systemPrompt: String
  let tokens: [Int]
  let cache: VisionKVCacheBox
}

private final class VisionKVCacheBox: @unchecked Sendable {
  let value: [KVCache]

  init(_ value: [KVCache]) {
    self.value = value
  }
}
