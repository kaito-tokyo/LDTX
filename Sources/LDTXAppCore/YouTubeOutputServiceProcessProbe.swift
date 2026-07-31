// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import LDTXYouTubeOutputProtocol

  public struct YouTubeOutputServiceProcessProbeResult: Equatable, Sendable {
    public var context: YouTubeOutputContext
    public var nextMediaSegmentNumber: Int?
    public var configurationFingerprint: String?
    public var availabilityStartTime: Date?

    public init(context: YouTubeOutputContext, nextMediaSegmentNumber: Int?, configurationFingerprint: String?, availabilityStartTime: Date?) {
      self.context = context
      self.nextMediaSegmentNumber = nextMediaSegmentNumber
      self.configurationFingerprint = configurationFingerprint
      self.availabilityStartTime = availabilityStartTime
    }
  }

  public enum YouTubeOutputServiceProcessProbe {
    public static func run(
      completionHandler:
        @escaping @Sendable (Result<YouTubeOutputServiceProcessProbeResult, any Error>) -> Void
    ) {
      YouTubeOutputServiceProcessProbeOperation(completionHandler: completionHandler).start()
    }
  }

  private final class YouTubeOutputServiceProcessProbeOperation: NSObject, @unchecked Sendable {
    private let connection = NSXPCConnection(
      serviceName: LDTXYouTubeOutputServiceProcessInterfaces.serviceName)
    private let completionHandler:
      @Sendable (
        Result<YouTubeOutputServiceProcessProbeResult, any Error>
      ) -> Void
    private let lock = NSLock()
    private var isComplete = false
    private let bootstrap: YouTubeOutputBootstrap
    private let sharedVideoMemory: FileHandle

    init(
      completionHandler:
        @escaping @Sendable (
          Result<YouTubeOutputServiceProcessProbeResult, any Error>
        ) -> Void
    ) {
      self.completionHandler = completionHandler
      var template = Array("/tmp/ldtx-probe-XXXXXX".utf8CString)
      let descriptor = mkstemp(&template)
      precondition(descriptor >= 0 && ftruncate(descriptor, 4_096) == 0)
      unlink(template)
      sharedVideoMemory = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
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
        persistenceIdentifier: "integration-output",
        sharedVideoSlotCount: 1,
        sharedVideoSlotSize: 4_096)
      super.init()
    }

    func start() {
      connection.remoteObjectInterface = LDTXYouTubeOutputServiceProcessInterfaces.service()
      connection.exportedInterface = LDTXYouTubeOutputServiceProcessInterfaces.client()
      connection.exportedObject = self
      connection.interruptionHandler = { [weak self] in
        self?.complete(.failure(YouTubeOutputServiceProcessProbeError.interrupted))
      }
      connection.invalidationHandler = { [weak self] in
        self?.complete(.failure(YouTubeOutputServiceProcessProbeError.invalidated))
      }
      connection.resume()
      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
          self?.complete(.failure(error))
        }) as? LDTXYouTubeOutputServiceProcessXPC
      else {
        complete(.failure(YouTubeOutputServiceProcessProbeError.unavailable))
        return
      }
      do {
        let request = try YouTubeOutputCoding.encode(bootstrap)
        proxy.bootstrap(request, sharedVideoMemory: sharedVideoMemory) { [weak self] data in
          self?.didBootstrap(data, proxy: proxy)
        }
      } catch {
        complete(.failure(error))
      }
    }

    private func didBootstrap(_ data: Data, proxy: LDTXYouTubeOutputServiceProcessXPC) {
      do {
        let reply = try YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: data)
        if let error = reply.errorDescription {
          throw YouTubeOutputServiceProcessProbeError.remote(error)
        }
        var repeatedBootstrap = bootstrap
        repeatedBootstrap.context.generation += 1
        proxy.bootstrap(
          try YouTubeOutputCoding.encode(repeatedBootstrap),
          sharedVideoMemory: sharedVideoMemory
        ) { [weak self] data in
          self?.didRepeatBootstrap(data, request: repeatedBootstrap, proxy: proxy)
        }
      } catch {
        complete(.failure(error))
      }
    }

    private func didRepeatBootstrap(
      _ data: Data,
      request: YouTubeOutputBootstrap,
      proxy: LDTXYouTubeOutputServiceProcessXPC
    ) {
      do {
        let reply = try YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: data)
        if let error = reply.errorDescription {
          throw YouTubeOutputServiceProcessProbeError.remote(error)
        }
        guard reply.context == request.context else {
          throw YouTubeOutputServiceProcessProbeError.invalidIdempotentContext
        }
        let result = YouTubeOutputServiceProcessProbeResult(
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
              throw YouTubeOutputServiceProcessProbeError.remote(error)
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

    private func complete(_ result: Result<YouTubeOutputServiceProcessProbeResult, any Error>) {
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

  extension YouTubeOutputServiceProcessProbeOperation: LDTXYouTubeOutputServiceProcessClientXPC {
    func serviceReservesCheckpoint(_ request: Data, withReply reply: @escaping (Data) -> Void) {
      reply(Data())
    }

    func serviceRequestsReset(_ request: Data) {
      complete(.failure(YouTubeOutputServiceProcessProbeError.resetRequested))
    }

    func serviceCommitsCheckpoint(_ request: Data) {}
    func serviceCommitsMediaCheckpoint(_ request: Data) {}
  }

  private enum YouTubeOutputServiceProcessProbeError: Error {
    case unavailable
    case interrupted
    case invalidated
    case invalidIdempotentContext
    case resetRequested
    case remote(String)
  }
