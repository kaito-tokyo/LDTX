// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import QuickLookUI

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
  func providePreview(
    for request: QLFilePreviewRequest,
    completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void
  ) {
    let mediaFileName = Self.preferredMediaFile(in: request.fileURL)
    let mediaURL = request.fileURL.appendingPathComponent(mediaFileName)
    quickLookPreviewLogger.notice(
      "Providing \(mediaFileName, privacy: .public) for \(request.fileURL.lastPathComponent, privacy: .public)."
    )
    handler(QLPreviewReply(fileURL: mediaURL), nil)
  }

  private static func preferredMediaFile(in packageURL: URL) -> String {
    let infoURL = packageURL.appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: infoURL),
      let info = try? PropertyListSerialization.propertyList(
        from: data, options: 0, format: nil) as? [String: Any]
    else { return "main.fragmented.mp4" }
    return info["LDTXRecordingLandscapeMediaFile"] as? String
      ?? info["LDTXRecordingPortraitMediaFile"] as? String
      ?? info["LDTXRecordingMainMediaFile"] as? String
      ?? "main.fragmented.mp4"
  }
}
