// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum VisionRuntimePresentationStatus: Equatable, Sendable {
  case unavailable
  case ready
  case analyzing
  case failed(message: String)
}

public struct VisionAnalysisPresentation: Equatable, Sendable {
  public var elapsedSeconds: TimeInterval
  public init(elapsedSeconds: TimeInterval) {
    self.elapsedSeconds = elapsedSeconds
  }
}

@MainActor
public protocol VisionRuntimePresenting: AnyObject {
  func status(forVisionID visionID: String) -> VisionRuntimePresentationStatus
  func result(forVisionID visionID: String) -> String?
  func analysis(forVisionID visionID: String) -> VisionAnalysisPresentation?
}
