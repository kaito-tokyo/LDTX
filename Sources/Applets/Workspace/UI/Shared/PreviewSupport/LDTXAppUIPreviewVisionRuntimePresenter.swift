// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
  import LDTXWorkspaceAppletInterface

  @MainActor
  final class LDTXAppUIPreviewVisionRuntimePresenter: VisionRuntimePresenting {
    func status(forVisionID visionID: String) -> VisionRuntimePresentationStatus {
      .ready
    }

    func result(forVisionID visionID: String) -> String? {
      nil
    }

    func analysis(forVisionID visionID: String) -> VisionAnalysisPresentation? {
      nil
    }
  }
#endif
