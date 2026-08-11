// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import LDTXRecording
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
  override func provideThumbnail(
    for request: QLFileThumbnailRequest,
    _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void
  ) {
    let mediaURL: URL
    do {
      mediaURL = try RecordingPackage(contentsOf: request.fileURL).mainMediaURL
    } catch {
      handler(nil, error)
      return
    }
    let minimumSize = request.minimumSize
    let maximumSize = request.maximumSize
    let requestScale = request.scale
    let completion = ThumbnailRequestCompletion(handler)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mediaURL))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(
      width: maximumSize.width * requestScale,
      height: maximumSize.height * requestScale
    )

    Task {
      do {
        let (image, _) = try await generator.image(at: .zero)
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(
          maximumSize.width / imageSize.width,
          maximumSize.height / imageSize.height
        )
        let fittedSize = CGSize(
          width: imageSize.width * scale,
          height: imageSize.height * scale
        )
        let contextSize = CGSize(
          width: min(max(fittedSize.width, minimumSize.width), maximumSize.width),
          height: min(max(fittedSize.height, minimumSize.height), maximumSize.height)
        )
        let drawRect = CGRect(
          x: (contextSize.width - fittedSize.width) / 2,
          y: (contextSize.height - fittedSize.height) / 2,
          width: fittedSize.width,
          height: fittedSize.height
        )
        let reply = QLThumbnailReply(contextSize: contextSize) { context in
          context.scaleBy(x: requestScale, y: requestScale)
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
