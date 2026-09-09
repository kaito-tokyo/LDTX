// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXInternalProtocols

extension VisionRuntimeStore: VisionRuntimePresenting {
  public func status(forVisionID visionID: String) -> VisionRuntimePresentationStatus {
    switch statusesByVisionID[visionID] ?? .ready {
    case .ready:
      .ready
    case .analyzing:
      .analyzing
    case .failed(let message):
      .failed(message: message)
    }
  }

  public func result(forVisionID visionID: String) -> String? {
    resultsByVisionID[visionID]
  }

  public func analysis(forVisionID visionID: String) -> VisionAnalysisPresentation? {
    guard let analysis = analysesByVisionID[visionID] else { return nil }
    return VisionAnalysisPresentation(elapsedSeconds: analysis.elapsedSeconds)
  }
}
