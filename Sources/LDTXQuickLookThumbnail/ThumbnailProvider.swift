// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import QuickLookThumbnailing

private final class ThumbnailRequestCompletion: @unchecked Sendable {
  private let handler: (QLThumbnailReply?, (any Error)?) -> Void

  init(_ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void) {
    self.handler = handler
  }

  func callAsFunction(_ reply: QLThumbnailReply?, _ error: (any Error)?) {
    handler(reply, error)
  }
}

final class ThumbnailProvider: QLThumbnailProvider {
  private static let mainMediaFileName = "main.fragmented.mp4"

  override func provideThumbnail(
    for request: QLFileThumbnailRequest,
    _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void
  ) {
    let mediaURL = request.fileURL.appendingPathComponent(Self.mainMediaFileName)
    let contextSize = request.maximumSize
    let requestScale = request.scale
    let completion = ThumbnailRequestCompletion(handler)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mediaURL))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(
      width: contextSize.width * requestScale,
      height: contextSize.height * requestScale
    )

    Task {
      do {
        let (image, _) = try await generator.image(at: .zero)
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = max(
          contextSize.width / imageSize.width,
          contextSize.height / imageSize.height
        )
        let drawSize = CGSize(
          width: imageSize.width * scale,
          height: imageSize.height * scale
        )
        let drawRect = CGRect(
          x: (contextSize.width - drawSize.width) / 2,
          y: (contextSize.height - drawSize.height) / 2,
          width: drawSize.width,
          height: drawSize.height
        )
        let reply = QLThumbnailReply(contextSize: contextSize) { context in
          context.draw(image, in: drawRect)
          return true
        }
        reply.extensionBadge = "LDTX"
        completion(reply, nil)
      } catch {
        completion(nil, error)
      }
    }
  }
}
