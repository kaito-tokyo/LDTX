// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXInternalProtocols

@MainActor
final class UnavailableVisionRuntimePresenter: VisionRuntimePresenting {
  func status(forVisionID visionID: String) -> VisionRuntimePresentationStatus {
    .unavailable
  }

  func result(forVisionID visionID: String) -> String? {
    nil
  }

  func analysis(forVisionID visionID: String) -> VisionAnalysisPresentation? {
    nil
  }
}
