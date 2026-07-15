// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXMP4
import LDTXYouTubeOutputProtocol
import OSLog

private let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "output-service")

private final class YouTubeOutputSession: NSObject, LDTXYouTubeOutputServiceXPC, @unchecked Sendable
{
  private weak var connection: NSXPCConnection?
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.youtube-output-service.session")
  private var context: YouTubeOutputContext?
  private var pipeline: DASHLiveUploadPipeline?
  private var mediaProcessor: YouTubeOutputMediaProcessor?
  private var sequenceGate: YouTubeOutputSequenceGate?
  private var nextMediaSegmentNumber: Int?
  private var initializationSegment: Data?
  private var configurationFingerprint: String?
  private var availabilityStartTime: Date?
  private var generatedUploads = DASHUploadFinalizationState()

  init(connection: NSXPCConnection) {
    self.connection = connection
  }

  func bootstrap(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let reply = XPCReply(reply)
    queue.async { [self] in
      do {
        let request = try YouTubeOutputCoding.decode(YouTubeOutputBootstrap.self, from: request)
        guard request.protocolVersion == LDTXYouTubeOutputServiceInterfaces.protocolVersion else {
          throw ServiceError(
            "Unsupported output service protocol version \(request.protocolVersion).")
        }
        let endpoint = DASHIngestEndpoint(baseURL: request.endpoint)
        let representation = request.representation
        pipeline = DASHLiveUploadPipeline(
          endpoint: endpoint,
          manifestConfiguration: DASHManifestConfiguration(
            availabilityStartTime: request.availabilityStartTime,
            timescale: request.timescale,
            segmentDurationSeconds: request.segmentDurationSeconds,
            startNumber: request.startNumber,
            mediaTemplate: request.mediaTemplate,
            initialization: .embedded(data: request.initializationSegment ?? Data()),
            representation: DASHRepresentation(
              id: representation.id,
              bandwidth: representation.bandwidth,
              width: representation.width,
              height: representation.height,
              frameRate: representation.frameRate,
              codecs: representation.codecs,
              audioSamplingRate: representation.audioSamplingRate
            )
          )
        )
        mediaProcessor = YouTubeOutputMediaProcessor(
          segmentDurationSeconds: request.segmentDurationSeconds,
          startNumber: request.startNumber
        ) { [weak self] result in
          guard let self else { return }
          queue.async {
            switch result {
            case .success(let segment): self.uploadGeneratedSegment(segment)
            case .failure(let error):
              self.generatedUploads.recordFailure(error)
              if let context = self.context { self.requestReset(error, context: context) }
            }
          }
        }
        context = request.context
        sequenceGate = YouTubeOutputSequenceGate(context: request.context)
        nextMediaSegmentNumber = request.startNumber
        initializationSegment = request.initializationSegment
        configurationFingerprint = request.configurationFingerprint
        availabilityStartTime = request.availabilityStartTime
        generatedUploads = DASHUploadFinalizationState()
        reply.send(
          try YouTubeOutputCoding.encode(
            YouTubeOutputReply(
              context: request.context,
              nextMediaSegmentNumber: request.startNumber,
              initializationSegment: request.initializationSegment,
              configurationFingerprint: request.configurationFingerprint,
              availabilityStartTime: request.availabilityStartTime)))
      } catch {
        reply.send(Self.errorReply(error, fallbackContext: nil))
      }
    }
  }

  func appendMediaBatch(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let reply = XPCReply(reply)
    queue.async { [self] in
      do {
        let request = try YouTubeOutputCoding.decode(YouTubeOutputMediaBatch.self, from: request)
        guard var sequenceGate else { throw ServiceError("Output sequence gate is unavailable.") }
        try sequenceGate.accept(request)
        self.sequenceGate = sequenceGate
        guard let mediaProcessor else {
          throw ServiceError("Output media processor is unavailable.")
        }
        try mediaProcessor.append(request)
        reply.send(
          try YouTubeOutputCoding.encode(
            YouTubeOutputReply(
              context: request.context,
              sequence: request.sequence,
              configurationFingerprint: configurationFingerprint)))
      } catch {
        let fallback = self.context
        reply.send(Self.errorReply(error, fallbackContext: fallback))
        if let fallback { requestReset(error, context: fallback) }
      }
    }
  }

  func finish(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let reply = XPCReply(reply)
    queue.async { [self] in
      do {
        let request = try YouTubeOutputCoding.decode(YouTubeOutputFinishRequest.self, from: request)
        guard request.context == context else {
          throw ServiceError("Output finish context is invalid.")
        }
        if let mediaProcessor {
          mediaProcessor.finish { [weak self] result in
            guard let self else { return }
            queue.async {
              self.mediaProcessor = nil
              switch result {
              case .success:
                self.finishAfterGeneratedUploads(
                  context: request.context, reply: reply)
              case .failure(let error):
                reply.send(Self.errorReply(error, fallbackContext: request.context))
              }
            }
          }
        } else {
          let response = try finishResponse(context: request.context)
          pipeline = nil
          context = nil
          configurationFingerprint = nil
          availabilityStartTime = nil
          reply.send(response)
        }
      } catch {
        reply.send(Self.errorReply(error, fallbackContext: context))
      }
    }
  }

  private func uploadGeneratedSegment(_ segment: SegmentedMP4Segment) {
    guard let pipeline, let context else { return }
    if case .initialization = segment.kind {
      initializationSegment = segment.data
    }
    generatedUploads.beginUpload()
    pipeline.upload(segment) { [weak self] result in
      guard let self else { return }
      queue.async {
        switch result {
        case .success:
          self.generatedUploads.completeUpload()
          if case .media(let number) = segment.kind {
            self.nextMediaSegmentNumber = max(self.nextMediaSegmentNumber ?? 1, number + 1)
          }
          self.commitCheckpoint(context: context)
        case .failure(let error):
          self.generatedUploads.completeUpload(error: error)
          self.requestReset(error, context: context)
        }
      }
    }
  }

  private func finishAfterGeneratedUploads(
    context: YouTubeOutputContext,
    reply: XPCReply
  ) {
    guard generatedUploads.pendingCount == 0 else {
      queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
        self?.finishAfterGeneratedUploads(context: context, reply: reply)
      }
      return
    }
    do {
      try generatedUploads.validateFinished()
      let response = try finishResponse(context: context)
      pipeline = nil
      self.context = nil
      configurationFingerprint = nil
      availabilityStartTime = nil
      reply.send(response)
    } catch {
      reply.send(Self.errorReply(error, fallbackContext: context))
    }
  }

  private func finishResponse(context: YouTubeOutputContext) throws -> Data {
    try YouTubeOutputCoding.encode(
      YouTubeOutputReply(
        context: context,
        nextMediaSegmentNumber: nextMediaSegmentNumber,
        initializationSegment: initializationSegment,
        configurationFingerprint: configurationFingerprint,
        availabilityStartTime: availabilityStartTime))
  }

  private func requestReset(_ error: Error, context: YouTubeOutputContext) {
    guard let proxy = connection?.remoteObjectProxy as? LDTXYouTubeOutputServiceClientXPC,
      let data = try? YouTubeOutputCoding.encode(
        YouTubeOutputResetRequest(
          context: context,
          reason: error.localizedDescription,
          nextMediaSegmentNumber: nextMediaSegmentNumber,
          initializationSegment: initializationSegment,
          configurationFingerprint: configurationFingerprint,
          availabilityStartTime: availabilityStartTime
        ))
    else { return }
    proxy.serviceRequestsReset(data)
  }

  private func commitCheckpoint(context: YouTubeOutputContext) {
    guard let proxy = connection?.remoteObjectProxy as? LDTXYouTubeOutputServiceClientXPC,
      let data = try? YouTubeOutputCoding.encode(
        YouTubeOutputResetRequest(
          context: context,
          reason: "",
          nextMediaSegmentNumber: nextMediaSegmentNumber,
          initializationSegment: initializationSegment,
          configurationFingerprint: configurationFingerprint,
          availabilityStartTime: availabilityStartTime
        ))
    else { return }
    proxy.serviceCommitsCheckpoint(data)
  }

  private static func errorReply(_ error: Error, fallbackContext: YouTubeOutputContext?) -> Data {
    guard let context = fallbackContext,
      let data = try? YouTubeOutputCoding.encode(
        YouTubeOutputReply(
          context: context,
          errorDescription: error.localizedDescription
        ))
    else { return Data() }
    return data
  }

}

private final class XPCReply: @unchecked Sendable {
  private let reply: (Data) -> Void
  init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
  func send(_ data: Data) { reply(data) }
}

private struct ServiceError: LocalizedError {
  var message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

private final class YouTubeOutputListenerDelegate: NSObject, NSXPCListenerDelegate {
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    let session = YouTubeOutputSession(connection: connection)
    connection.exportedInterface = LDTXYouTubeOutputServiceInterfaces.service()
    connection.exportedObject = session
    connection.remoteObjectInterface = LDTXYouTubeOutputServiceInterfaces.client()
    connection.invalidationHandler = { _ = session }
    connection.resume()
    logger.notice("Accepted output service connection")
    return true
  }
}

private let delegate = YouTubeOutputListenerDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
