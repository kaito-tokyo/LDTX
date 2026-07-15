// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct DASHUploadFinalizationState: Sendable {
  public private(set) var pendingCount = 0
  public private(set) var failureDescription: String?

  public init() {}

  public mutating func beginUpload() {
    pendingCount += 1
  }

  public mutating func completeUpload(error: (any Error)? = nil) {
    pendingCount = max(pendingCount - 1, 0)
    if let error { recordFailure(error) }
  }

  public mutating func recordFailure(_ error: any Error) {
    failureDescription = failureDescription ?? error.localizedDescription
  }

  public func validateFinished() throws {
    guard pendingCount == 0 else {
      throw DASHUploadFinalizationError.uploadsPending(pendingCount)
    }
    if let failureDescription {
      throw DASHUploadFinalizationError.uploadFailed(failureDescription)
    }
  }
}

public enum DASHUploadFinalizationError: Error, LocalizedError, Equatable {
  case uploadsPending(Int)
  case uploadFailed(String)

  public var errorDescription: String? {
    switch self {
    case .uploadsPending(let count): "DASH output still has \(count) pending upload(s)."
    case .uploadFailed(let description): "DASH output upload failed: \(description)"
    }
  }
}
