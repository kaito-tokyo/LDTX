// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXMP4
import LDTXTaskQueue
import LDTXYouTubeOutputProtocol
import OSLog

private let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "output-service")

private final class YouTubeOutputServiceProcess: @unchecked Sendable {
  private struct ResourceTask: @unchecked Sendable {
    let execute: @Sendable () -> Void
  }

  private weak var connection: NSXPCConnection?
  private let timerQueue = DispatchQueue(label: "tokyo.kaito.ldtx.youtube-output-service.timers")
  private lazy var resourceQueue = ResourceTaskQueue<ResourceTask>(
    label: "tokyo.kaito.ldtx.youtube-output-service.resources", logger: .disabled
  ) { task, _, _ in
    task.execute()
  }
  private lazy var commandQueue = SessionTaskQueue(
    label: "tokyo.kaito.ldtx.youtube-output-service.commands",
    logger: .disabled)
  private var context: YouTubeOutputContext?
  private var pipeline: DASHLiveUploadPipeline?
  private var mediaProcessor: YouTubeOutputMediaProcessor?
  private var sharedVideoMemory: SharedH264MemoryReader?
  private var videoCodecString: String?
  private var sequenceGate: YouTubeOutputSequenceGate?
  private var nextMediaSegmentNumber: Int?
  private var initializationSegment: Data?
  private var configurationFingerprint: String?
  private var availabilityStartTime: Date?
  private var nextMediaTimeSeconds: Double?
  private var generatedUploads = DASHUploadFinalizationState()
  private var generatedSegmentTimes: [Int: ContinuousClock.Instant] = [:]

  func bootstrap(
    _ request: Data,
    sharedVideoMemory: FileHandle,
    connection: NSXPCConnection,
    withReply reply: @escaping (Data) -> Void
  ) {
    let connectionReference = XPCConnectionReference(connection)
    submitCommand(reply: reply) { [self] reply in
      do {
        let request = try YouTubeOutputCoding.decode(YouTubeOutputBootstrap.self, from: request)
        guard request.protocolVersion == LDTXYouTubeOutputServiceProcessInterfaces.protocolVersion else {
          throw ServiceError(
            "Unsupported output service protocol version \(request.protocolVersion).")
        }
        self.connection = connectionReference.value
        self.sharedVideoMemory = try SharedH264MemoryReader(
          handle: sharedVideoMemory,
          slotCount: request.sharedVideoSlotCount,
          slotSize: request.sharedVideoSlotSize)
        // Each bootstrap is a new media session. The WorkspaceService owns
        // ephemeral DASH continuity in memory and supplies it in this request.
        let endpoint = DASHIngestEndpoint(baseURL: request.endpoint)
        let representation = request.representation
        pipeline = DASHLiveUploadPipeline(
          endpoint: endpoint,
          manifestConfiguration: DASHManifestConfiguration(
            availabilityStartTime: request.availabilityStartTime,
            timescale: request.timescale,
            segmentTimeline: [],
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
          ),
          diagnosticContext: DASHLiveUploadDiagnosticContext(
            sessionID: request.context.sessionID,
            revision: request.context.revision),
          manifestStateHandler: { [weak self] state in
            self?.post { [weak self] in self?.commitManifestState(state) }
          }
        )
        let outputTimescale = max(request.timescale, 1)
        let outputOffsetSeconds = request.nextMediaTimeSeconds ?? 1
        mediaProcessor = YouTubeOutputMediaProcessor(
          startNumber: request.startNumber,
          outputOffset: YouTubeOutputMediaTime(
            value: Int64((outputOffsetSeconds * Double(outputTimescale)).rounded()),
            timescale: Int32(outputTimescale)
          )
        ) { [weak self] result in
          guard let self else { return }
          post {
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
        nextMediaTimeSeconds = request.nextMediaTimeSeconds ?? 1
        videoCodecString = nil
        generatedUploads = DASHUploadFinalizationState()
        generatedSegmentTimes = [:]
        let availabilityStartMilliseconds = Int64(
          (request.availabilityStartTime.timeIntervalSince1970 * 1_000).rounded())
        logger.notice(
          "[event:dash.session.begin] session=\(request.context.sessionID.uuidString, privacy: .public) revision=\(request.context.revision, privacy: .public) resume=\(request.startNumber > 1 || request.nextMediaTimeSeconds != nil, privacy: .public) startSegment=\(request.startNumber, privacy: .public) nextMediaMs=\(Self.milliseconds(outputOffsetSeconds), privacy: .public) timescale=\(request.timescale, privacy: .public) availabilityStartMs=\(availabilityStartMilliseconds, privacy: .public) hasInitialization=\(request.initializationSegment != nil, privacy: .public)"
        )
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
    submitCommand(reply: reply) { [self] reply in
      do {
        var request = try YouTubeOutputCoding.decode(YouTubeOutputMediaBatch.self, from: request)
        guard var sequenceGate else { throw ServiceError("Output sequence gate is unavailable.") }
        try sequenceGate.accept(request)
        self.sequenceGate = sequenceGate
        guard let mediaProcessor else {
          throw ServiceError("Output media processor is unavailable.")
        }
        guard let sharedVideoMemory else {
          throw ServiceError("Shared H.264 memory is unavailable.")
        }
        for index in request.video.indices {
          guard let slice = request.video[index].sharedMemory else {
            throw ServiceError("An H.264 access unit did not reference Workspace shared memory.")
          }
          request.video[index].avccData = try sharedVideoMemory.read(slice)
          request.video[index].sharedMemory = nil
        }
        if let format = request.videoFormat {
          guard let codecString = format.codecString else {
            throw ServiceError("The H.264 format does not contain a valid SPS codec identifier.")
          }
          if let videoCodecString, videoCodecString != codecString {
            throw ServiceError(
              "The H.264 codec changed from \(videoCodecString) to \(codecString) during one output session.")
          }
          videoCodecString = codecString
          pipeline?.setVideoCodecString(codecString, audioCodecString: "mp4a.40.2")
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
    let accepted = submitCommand(reply: reply) { [self] reply in
      do {
        let request = try YouTubeOutputCoding.decode(YouTubeOutputFinishRequest.self, from: request)
        guard request.context == context else {
          throw ServiceError("Output finish context is invalid.")
        }
        if let mediaProcessor {
          mediaProcessor.finish { [weak self] result in
            guard let self else { return }
            post {
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
          closeResourceQueueAfterDraining()
        }
      } catch {
        reply.send(Self.errorReply(error, fallbackContext: context))
      }
    }
    if accepted { commandQueue.finish() }
  }

  func stop() {
    commandQueue.stop()
    let queue = resourceQueue
    _Concurrency.Task { await queue.finishAfterDraining() }
  }

  @discardableResult
  private func submitCommand(
    reply: @escaping (Data) -> Void,
    operation: @escaping @Sendable (XPCReply) -> Void
  ) -> Bool {
    let response = XPCReply(reply)
    let accepted = commandQueue.submit(
      key: SessionTaskKey(UUID().uuidString), source: .normal
    ) { completion in
      { [weak self] stopToken, _ in
        guard let self else {
          completion()
          return
        }
        guard !stopToken.isStopRequested else {
          response.bind(completion: completion)
          response.send(Data())
          return
        }
        response.bind(completion: completion)
        self.post { operation(response) }
      }
    }
    if !accepted { response.send(Data()) }
    return accepted
  }

  private func uploadGeneratedSegment(_ segment: SegmentedMP4Segment) {
    guard let pipeline, let context else { return }
    if case .initialization = segment.kind {
      initializationSegment = segment.data
    }
    // Reservation acknowledgement is part of the upload transaction. Finish
    // must wait even when the HTTP PUT has not started yet.
    generatedUploads.beginUpload()
    if case .media(let number) = segment.kind {
      generatedSegmentTimes[number] = .now
      reserveMediaSegment(segment, number: number, context: context, pipeline: pipeline)
      return
    }
    startUpload(segment, context: context, pipeline: pipeline)
  }

  private func reserveMediaSegment(
    _ segment: SegmentedMP4Segment,
    number: Int,
    context: YouTubeOutputContext,
    pipeline: DASHLiveUploadPipeline
  ) {
    let reservedNumber = max(nextMediaSegmentNumber ?? 1, number + 1)
    let reservedTime: Double?
    if let start = segment.earliestPresentationTimeSeconds,
      let duration = segment.durationSeconds,
      start.isFinite, duration.isFinite, duration > 0
    {
      reservedTime = max(nextMediaTimeSeconds ?? 1, start + duration)
    } else {
      reservedTime = nextMediaTimeSeconds
    }
    guard let proxy = connection?.remoteObjectProxy as? LDTXYouTubeOutputServiceProcessClientXPC,
      let data = checkpointData(
        context: context,
        nextMediaSegmentNumber: reservedNumber,
        nextMediaTimeSeconds: reservedTime)
    else {
      let error = ServiceError("Could not reserve DASH media continuity.")
      generatedUploads.completeUpload(error: error)
      requestReset(error, context: context)
      return
    }
    proxy.serviceReservesCheckpoint(data) { [weak self] response in
      guard let self else { return }
      self.post {
        guard self.context == context,
          let reply = try? YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: response),
          reply.context == context,
          reply.configurationFingerprint == self.configurationFingerprint,
          reply.nextMediaSegmentNumber == reservedNumber
        else {
          let error = ServiceError("Workspace rejected DASH media reservation.")
          self.generatedUploads.completeUpload(error: error)
          self.requestReset(error, context: context)
          return
        }
        self.nextMediaSegmentNumber = reservedNumber
        self.nextMediaTimeSeconds = reservedTime
        self.startUpload(segment, context: context, pipeline: pipeline)
      }
    }
  }

  private func startUpload(
    _ segment: SegmentedMP4Segment,
    context: YouTubeOutputContext,
    pipeline: DASHLiveUploadPipeline
  ) {
    pipeline.upload(segment) { [weak self] result in
      guard let self else { return }
      post {
        switch result {
        case .success(let event):
          self.generatedUploads.completeUpload()
          if case .media(let number) = segment.kind {
            let deliveryMilliseconds = self.generatedSegmentTimes.removeValue(forKey: number).map {
              Self.milliseconds($0.duration(to: .now))
            } ?? -1
            self.nextMediaSegmentNumber = max(self.nextMediaSegmentNumber ?? 1, number + 1)
            if let start = segment.earliestPresentationTimeSeconds,
              let duration = segment.durationSeconds,
              start.isFinite, duration.isFinite, duration > 0
            {
              self.nextMediaTimeSeconds = max(self.nextMediaTimeSeconds ?? 1, start + duration)
            }
            let diagnostics = segment.diagnostics
            logger.notice(
              "[event:dash.segment.delivered] session=\(context.sessionID.uuidString, privacy: .public) revision=\(context.revision, privacy: .public) segment=\(number, privacy: .public) startMs=\(Self.milliseconds(segment.earliestPresentationTimeSeconds), privacy: .public) durationMs=\(Self.milliseconds(segment.durationSeconds), privacy: .public) bytes=\(segment.data.count, privacy: .public) videoSamples=\(diagnostics?.videoSampleCount ?? -1, privacy: .public) audioSamples=\(diagnostics?.audioSampleCount ?? -1, privacy: .public) audioFrames=\(diagnostics?.audioFrameCount ?? -1, privacy: .public) syncSamples=\(diagnostics?.syncVideoSampleCount ?? -1, privacy: .public) maxSyncGapMs=\(Self.milliseconds(diagnostics?.maximumSyncVideoIntervalSeconds), privacy: .public) deliveryMs=\(deliveryMilliseconds, privacy: .public) nextSegment=\(self.nextMediaSegmentNumber ?? -1, privacy: .public) nextMediaMs=\(Self.milliseconds(self.nextMediaTimeSeconds), privacy: .public)"
            )
          } else if case .initializationPrepared(let byteCount) = event {
            logger.notice(
              "[event:dash.initialization.prepared] session=\(context.sessionID.uuidString, privacy: .public) revision=\(context.revision, privacy: .public) bytes=\(byteCount, privacy: .public)"
            )
          }
          self.commitCheckpoint(
            context: context,
            deliveredMedia: {
              if case .media = segment.kind { return true }
              return false
            }())
        case .failure(let error):
          var deliveryMilliseconds: Int64 = -1
          if case .media(let number) = segment.kind {
            deliveryMilliseconds = self.generatedSegmentTimes.removeValue(forKey: number).map {
              Self.milliseconds($0.duration(to: .now))
            } ?? -1
          }
          let diagnostics = segment.diagnostics
          logger.error(
            "[event:dash.delivery.failed] session=\(context.sessionID.uuidString, privacy: .public) revision=\(context.revision, privacy: .public) kind=\(Self.kindDescription(segment.kind), privacy: .public) startMs=\(Self.milliseconds(segment.earliestPresentationTimeSeconds), privacy: .public) durationMs=\(Self.milliseconds(segment.durationSeconds), privacy: .public) bytes=\(segment.data.count, privacy: .public) syncSamples=\(diagnostics?.syncVideoSampleCount ?? -1, privacy: .public) maxSyncGapMs=\(Self.milliseconds(diagnostics?.maximumSyncVideoIntervalSeconds), privacy: .public) deliveryMs=\(deliveryMilliseconds, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
          )
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
      timerQueue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
        self?.post { [weak self] in
          self?.finishAfterGeneratedUploads(context: context, reply: reply)
        }
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
      closeResourceQueueAfterDraining()
    } catch {
      reply.send(Self.errorReply(error, fallbackContext: context))
    }
  }

  private func finishResponse(context: YouTubeOutputContext) throws -> Data {
    logger.notice(
      "[event:dash.session.end] session=\(context.sessionID.uuidString, privacy: .public) revision=\(context.revision, privacy: .public) nextSegment=\(self.nextMediaSegmentNumber ?? -1, privacy: .public) nextMediaMs=\(Self.milliseconds(self.nextMediaTimeSeconds), privacy: .public) pendingUploads=\(self.generatedUploads.pendingCount, privacy: .public)"
    )
    return try YouTubeOutputCoding.encode(
      YouTubeOutputReply(
        context: context,
        nextMediaSegmentNumber: nextMediaSegmentNumber,
        initializationSegment: initializationSegment,
        configurationFingerprint: configurationFingerprint,
        availabilityStartTime: availabilityStartTime))
  }

  /// Publishes MPD state to the WorkspaceService, which owns the in-memory cache.
  private func commitManifestState(_ state: DASHLiveUploadManifestState) {
    availabilityStartTime = state.availabilityStartTime
    nextMediaSegmentNumber = max(nextMediaSegmentNumber ?? state.startNumber, state.startNumber)
    if let context { commitCheckpoint(context: context) }
  }

  private func requestReset(_ error: Error, context: YouTubeOutputContext) {
    logger.error(
      "[event:dash.session.reset-requested] session=\(context.sessionID.uuidString, privacy: .public) revision=\(context.revision, privacy: .public) nextSegment=\(self.nextMediaSegmentNumber ?? -1, privacy: .public) nextMediaMs=\(Self.milliseconds(self.nextMediaTimeSeconds), privacy: .public) pendingUploads=\(self.generatedUploads.pendingCount, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
    )
    guard let proxy = connection?.remoteObjectProxy as? LDTXYouTubeOutputServiceProcessClientXPC,
      let data = try? YouTubeOutputCoding.encode(
        YouTubeOutputResetRequest(
          context: context,
          reason: error.localizedDescription,
          nextMediaSegmentNumber: nextMediaSegmentNumber,
          initializationSegment: initializationSegment,
          configurationFingerprint: configurationFingerprint,
          availabilityStartTime: availabilityStartTime,
          nextMediaTimeSeconds: nextMediaTimeSeconds
        ))
    else { return }
    proxy.serviceRequestsReset(data)
  }

  private func commitCheckpoint(context: YouTubeOutputContext, deliveredMedia: Bool = false) {
    guard let proxy = connection?.remoteObjectProxy as? LDTXYouTubeOutputServiceProcessClientXPC,
      let data = try? YouTubeOutputCoding.encode(
        YouTubeOutputResetRequest(
          context: context,
          reason: "",
          nextMediaSegmentNumber: nextMediaSegmentNumber,
          initializationSegment: initializationSegment,
          configurationFingerprint: configurationFingerprint,
          availabilityStartTime: availabilityStartTime,
          nextMediaTimeSeconds: nextMediaTimeSeconds
        ))
    else { return }
    if deliveredMedia {
      proxy.serviceCommitsMediaCheckpoint(data)
    } else {
      proxy.serviceCommitsCheckpoint(data)
    }
  }

  private func checkpointData(
    context: YouTubeOutputContext,
    nextMediaSegmentNumber: Int?,
    nextMediaTimeSeconds: Double?
  ) -> Data? {
    try? YouTubeOutputCoding.encode(
      YouTubeOutputResetRequest(
        context: context,
        reason: "",
        nextMediaSegmentNumber: nextMediaSegmentNumber,
        initializationSegment: initializationSegment,
        configurationFingerprint: configurationFingerprint,
        availabilityStartTime: availabilityStartTime,
        nextMediaTimeSeconds: nextMediaTimeSeconds))
  }

  @discardableResult
  private func post(_ body: @escaping @Sendable () -> Void) -> Bool {
    resourceQueue.post(ResourceTask(execute: body))
  }

  private func closeResourceQueueAfterDraining() {
    let queue = resourceQueue
    _Concurrency.Task { await queue.finishAfterDraining() }
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

  private static func milliseconds(_ seconds: Double?) -> Int64 {
    guard let seconds, seconds.isFinite else { return -1 }
    return Int64(clamping: Int((seconds * 1_000).rounded()))
  }

  private static func milliseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
    guard !seconds.overflow else { return .max }
    return seconds.partialValue + Int64(components.attoseconds / 1_000_000_000_000_000)
  }

  private static func kindDescription(_ kind: SegmentedMP4SegmentKind) -> String {
    switch kind {
    case .initialization: "initialization"
    case .media(let number): "media:\(number)"
    }
  }

}

private final class XPCReply: @unchecked Sendable {
  private let lock = NSLock()
  private var reply: ((Data) -> Void)?
  private var completion: (@Sendable () -> Void)?

  init(
    _ reply: @escaping (Data) -> Void,
    completion: @escaping @Sendable () -> Void = {}
  ) {
    self.reply = reply
    self.completion = completion
  }

  func send(_ data: Data) {
    let actions = lock.withLock {
      let actions = (reply, completion)
      reply = nil
      completion = nil
      return actions
    }
    actions.0?(data)
    actions.1?()
  }

  func bind(completion: @escaping @Sendable () -> Void) {
    lock.withLock {
      guard reply != nil else { return }
      self.completion = completion
    }
  }
}

/// Foundation's XPC objects predate Sendable. Access to the wrapped reference
/// is confined to the ServiceProcess serial queue.
private final class XPCConnectionReference: @unchecked Sendable {
  weak var value: NSXPCConnection?

  init(_ value: NSXPCConnection) {
    self.value = value
  }
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
    let session = YouTubeOutputServiceProcess()
    connection.exportedInterface = LDTXYouTubeOutputServiceProcessInterfaces.service()
    connection.exportedObject = YouTubeOutputConnection(session: session, connection: connection)
    connection.remoteObjectInterface = LDTXYouTubeOutputServiceProcessInterfaces.client()
    connection.invalidationHandler = { session.stop() }
    connection.resume()
    logger.notice("Accepted output service connection")
    return true
  }
}

/// Keeps the caller connection associated with its isolated ServiceProcess session.
private final class YouTubeOutputConnection: NSObject, LDTXYouTubeOutputServiceProcessXPC,
  @unchecked Sendable
{
  private let session: YouTubeOutputServiceProcess
  private weak var connection: NSXPCConnection?

  init(session: YouTubeOutputServiceProcess, connection: NSXPCConnection) {
    self.session = session
    self.connection = connection
  }

  func bootstrap(
    _ request: Data,
    sharedVideoMemory: FileHandle,
    withReply reply: @escaping (Data) -> Void
  ) {
    guard let connection else { return reply(Data()) }
    session.bootstrap(
      request, sharedVideoMemory: sharedVideoMemory,
      connection: connection, withReply: reply)
  }

  func appendMediaBatch(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    session.appendMediaBatch(request, withReply: reply)
  }

  func finish(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    session.finish(request, withReply: reply)
  }
}

private let delegate = YouTubeOutputListenerDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
