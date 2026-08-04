// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import QuickLookUI

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
  private static let mainMediaFileName = "main.fragmented.mp4"

  func providePreview(
    for request: QLFilePreviewRequest,
    completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void
  ) {
    let mediaURL = request.fileURL.appendingPathComponent(Self.mainMediaFileName)
    quickLookPreviewLogger.notice(
      "Providing \(Self.mainMediaFileName, privacy: .public) for \(request.fileURL.lastPathComponent, privacy: .public)."
    )
    handler(QLPreviewReply(fileURL: mediaURL), nil)
  }
}
