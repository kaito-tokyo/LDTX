// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXYouTubeOutputProtocol

#if DEBUG
  struct YouTubeOutputXPCProbeResult: Equatable, Sendable {
    var context: YouTubeOutputContext
    var nextMediaSegmentNumber: Int?
    var configurationFingerprint: String?
    var availabilityStartTime: Date?
  }

  enum YouTubeOutputXPCProbe {
    static func run(
      completionHandler:
        @escaping @Sendable (Result<YouTubeOutputXPCProbeResult, any Error>) -> Void
    ) {
      YouTubeOutputXPCProbeOperation(completionHandler: completionHandler).start()
    }
  }

  private final class YouTubeOutputXPCProbeOperation: NSObject, @unchecked Sendable {
    private let connection = NSXPCConnection(
      serviceName: LDTXYouTubeOutputServiceInterfaces.serviceName)
    private let completionHandler:
      @Sendable (
        Result<YouTubeOutputXPCProbeResult, any Error>
      ) -> Void
    private let lock = NSLock()
    private var isComplete = false
    private let bootstrap: YouTubeOutputBootstrap

    init(
      completionHandler:
        @escaping @Sendable (
          Result<YouTubeOutputXPCProbeResult, any Error>
        ) -> Void
    ) {
      self.completionHandler = completionHandler
      bootstrap = YouTubeOutputBootstrap(
        context: YouTubeOutputContext(sessionID: UUID(), generation: 0),
        endpoint: URL(string: "https://example.invalid/upload")!,
        availabilityStartTime: Date(timeIntervalSince1970: 1_700_000_000.123),
        timescale: 1_000,
        segmentDurationSeconds: 2,
        startNumber: 9,
        mediaTemplate: "segment-$Number$.m4s",
        representation: YouTubeOutputRepresentation(
          id: "main",
          bandwidth: 2_000_000,
          width: 1_280,
          height: 720,
          frameRate: "30",
          codecs: "avc1.64001f,mp4a.40.2",
          audioSamplingRate: 48_000),
        configurationFingerprint: "integration-fingerprint",
        persistenceIdentifier: "integration-output")
      super.init()
    }

    func start() {
      connection.remoteObjectInterface = LDTXYouTubeOutputServiceInterfaces.service()
      connection.exportedInterface = LDTXYouTubeOutputServiceInterfaces.client()
      connection.exportedObject = self
      connection.interruptionHandler = { [weak self] in
        self?.complete(.failure(YouTubeOutputXPCProbeError.interrupted))
      }
      connection.invalidationHandler = { [weak self] in
        self?.complete(.failure(YouTubeOutputXPCProbeError.invalidated))
      }
      connection.resume()
      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
          self?.complete(.failure(error))
        }) as? LDTXYouTubeOutputServiceXPC
      else {
        complete(.failure(YouTubeOutputXPCProbeError.unavailable))
        return
      }
      do {
        let request = try YouTubeOutputCoding.encode(bootstrap)
        proxy.bootstrap(request) { [weak self] data in self?.didBootstrap(data, proxy: proxy) }
      } catch {
        complete(.failure(error))
      }
    }

    private func didBootstrap(_ data: Data, proxy: LDTXYouTubeOutputServiceXPC) {
      do {
        let reply = try YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: data)
        if let error = reply.errorDescription {
          throw YouTubeOutputXPCProbeError.remote(error)
        }
        var repeatedBootstrap = bootstrap
        repeatedBootstrap.context.generation += 1
        proxy.bootstrap(try YouTubeOutputCoding.encode(repeatedBootstrap)) { [weak self] data in
          self?.didRepeatBootstrap(data, request: repeatedBootstrap, proxy: proxy)
        }
      } catch {
        complete(.failure(error))
      }
    }

    private func didRepeatBootstrap(
      _ data: Data,
      request: YouTubeOutputBootstrap,
      proxy: LDTXYouTubeOutputServiceXPC
    ) {
      do {
        let reply = try YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: data)
        if let error = reply.errorDescription {
          throw YouTubeOutputXPCProbeError.remote(error)
        }
        guard reply.context == request.context else {
          throw YouTubeOutputXPCProbeError.invalidIdempotentContext
        }
        let result = YouTubeOutputXPCProbeResult(
          context: reply.context,
          nextMediaSegmentNumber: reply.nextMediaSegmentNumber,
          configurationFingerprint: reply.configurationFingerprint,
          availabilityStartTime: reply.availabilityStartTime)
        proxy.finish(
          try YouTubeOutputCoding.encode(YouTubeOutputFinishRequest(context: request.context))
        ) { [weak self] data in
          do {
            let reply = try YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: data)
            if let error = reply.errorDescription {
              throw YouTubeOutputXPCProbeError.remote(error)
            }
            self?.complete(.success(result))
          } catch {
            self?.complete(.failure(error))
          }
        }
      } catch {
        complete(.failure(error))
      }
    }

    private func complete(_ result: Result<YouTubeOutputXPCProbeResult, any Error>) {
      let shouldComplete = lock.withLock {
        guard !isComplete else { return false }
        isComplete = true
        return true
      }
      guard shouldComplete else { return }
      connection.interruptionHandler = nil
      connection.invalidationHandler = nil
      connection.invalidate()
      completionHandler(result)
    }
  }

  extension YouTubeOutputXPCProbeOperation: LDTXYouTubeOutputServiceClientXPC {
    func serviceRequestsReset(_ request: Data) {
      complete(.failure(YouTubeOutputXPCProbeError.resetRequested))
    }

    func serviceCommitsCheckpoint(_ request: Data) {}
  }

  private enum YouTubeOutputXPCProbeError: Error {
    case unavailable
    case interrupted
    case invalidated
    case invalidIdempotentContext
    case resetRequested
    case remote(String)
  }
#endif
