// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXRecording
import QuickLookUI

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
  func providePreview(
    for request: QLFilePreviewRequest,
    completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void
  ) {
    do {
      let package = try RecordingPackage(contentsOf: request.fileURL)
      quickLookPreviewLogger.notice(
        "Providing \(package.mainMediaPath, privacy: .public) for \(request.fileURL.lastPathComponent, privacy: .public)."
      )
      handler(QLPreviewReply(fileURL: package.mainMediaURL), nil)
    } catch {
      handler(nil, error)
    }
  }
}
