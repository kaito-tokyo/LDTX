// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum VisionRuntimePresentationStatus: Equatable, Sendable {
  case unavailable
  case notDownloaded
  case downloading(fractionCompleted: Double)
  case ready
  case analyzing
  case failed(message: String)
}

public struct VisionAnalysisPresentation: Equatable, Sendable {
  public var elapsedSeconds: TimeInterval
  public var promptTokenCount: Int?
  public var generationTokenCount: Int?
  public var tokensPerSecond: Double?
  public var memory: VisionMemoryPresentation

  public init(
    elapsedSeconds: TimeInterval,
    promptTokenCount: Int?,
    generationTokenCount: Int?,
    tokensPerSecond: Double?,
    memory: VisionMemoryPresentation
  ) {
    self.elapsedSeconds = elapsedSeconds
    self.promptTokenCount = promptTokenCount
    self.generationTokenCount = generationTokenCount
    self.tokensPerSecond = tokensPerSecond
    self.memory = memory
  }
}

public struct VisionMemoryPresentation: Equatable, Sendable {
  public var activeBytes: Int
  public var cachedBytes: Int
  public var peakActiveBytes: Int
  public var poolGrowthBytes: Int
  public var isPoolStable: Bool

  public init(
    activeBytes: Int,
    cachedBytes: Int,
    peakActiveBytes: Int,
    poolGrowthBytes: Int,
    isPoolStable: Bool
  ) {
    self.activeBytes = activeBytes
    self.cachedBytes = cachedBytes
    self.peakActiveBytes = peakActiveBytes
    self.poolGrowthBytes = poolGrowthBytes
    self.isPoolStable = isPoolStable
  }
}

@MainActor
public protocol VisionRuntimePresenting: AnyObject {
  func status(forVisionID visionID: String) -> VisionRuntimePresentationStatus
  func result(forVisionID visionID: String) -> String?
  func analysis(forVisionID visionID: String) -> VisionAnalysisPresentation?
}
