// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXOutputMedia
import LDTXRecordingXPCProtocol
import SwiftProtobuf

/// Nonblocking producer for the Main Program mux/disk-writer XPC.
///
/// H.264 and AAC use independent SPSC rings because they originate on
/// different realtime paths.  The XPC owns ordering, fMP4 muxing, flushing,
/// and durable fragment notifications; neither producer waits for it.
final class MainRecordingXPCClient: NSObject, LDTXRecordingWriterClientXPC, @unchecked Sendable {
  private static let videoCapacity = 16 * 1_024 * 1_024
  private static let audioCapacity = 8 * 1_024 * 1_024
  private let lock = NSLock()
  private let serviceName: String
  private let trackRecorder: HLSByteRangeTrackRecorder
  private let segmentDurationSeconds: Int
  private let failureHandler: @Sendable (Error) -> Void
  private let videoProducer: RecordingSharedRingProducer
  private let audioProducer: RecordingSharedRingProducer
  private var connection: NSXPCConnection?
  private var videoSequence: UInt64 = 0
  private var audioSequence: UInt64 = 0
  private var sentVideoFormat = false
  private var sentAudioFormat = false
  private var finishing = false
  private var failed = false
  private var startResultDelivered = false
  /// `finish` is a terminal barrier, not just an acknowledgement that the
  /// XPC accepted a request.  It completes only after the XPC has emitted its
  /// generation watermark, so the Coordinator can build its manifest from
  /// every durable fragment.
  private var awaitingGenerationFinished = false
  private var generationFinishedReceived = false
  private var pendingFinishCompletion: (@Sendable (Result<Void, Error>) -> Void)?
  private var finishCompletionDelivered = false

  init(trackRecorder: HLSByteRangeTrackRecorder, segmentDurationSeconds: Int,
       failureHandler: @escaping @Sendable (Error) -> Void) throws {
    guard let serviceName = Bundle.main.object(forInfoDictionaryKey: "LDTXMainRecordingServiceXPCServiceName") as? String,
      !serviceName.isEmpty else { throw MainRecordingXPCClientError.missingServiceName }
    self.serviceName = serviceName
    self.trackRecorder = trackRecorder
    self.segmentDurationSeconds = segmentDurationSeconds
    self.failureHandler = failureHandler
    videoProducer = try RecordingSharedRingProducer.create(capacity: Self.videoCapacity)
    audioProducer = try RecordingSharedRingProducer.create(capacity: Self.audioCapacity)
    super.init()
  }

  func start(sessionID: String, generation: Int = 1, completionHandler: @escaping @Sendable (Result<Void, Error>) -> Void) {
    lock.withLock { startResultDelivered = false }
    let completeOnce: @Sendable (Result<Void, Error>) -> Void = { [weak self] result in
      guard let self else { return }
      let shouldDeliver = self.lock.withLock {
        guard !self.startResultDelivered else { return false }
        self.startResultDelivered = true
        return true
      }
      guard shouldDeliver else { return }
      completionHandler(result)
    }
    let connection = NSXPCConnection(serviceName: serviceName)
    connection.remoteObjectInterface = LDTXRecordingWriterXPCInterfaces.service()
    connection.exportedInterface = LDTXRecordingWriterXPCInterfaces.client()
    connection.exportedObject = self
    connection.interruptionHandler = { [weak self] in self?.connectionFailed() }
    connection.invalidationHandler = { [weak self] in self?.connectionFailed() }
    connection.resume()
    lock.withLock { self.connection = connection }
    do {
      var request = Ldtx_Recording_Xpc_V1_MainConfigureRequest()
      request.protocolVersion = LDTXRecordingWriterXPCInterfaces.protocolVersion
      request.context.sessionID = sessionID
      request.context.generation = UInt64(max(generation, 1))
      request.videoRingCapacity = UInt64(Self.videoCapacity)
      request.audioRingCapacity = UInt64(Self.audioCapacity)
      request.segmentDurationSeconds = UInt32(segmentDurationSeconds)
      let output = try trackRecorder.makeOutputFileHandle()
      guard let service = connection.remoteObjectProxyWithErrorHandler({ error in completeOnce(.failure(error)) }) as? LDTXRecordingWriterServiceXPC else {
        throw MainRecordingXPCClientError.missingServiceProxy
      }
      service.configureMain(try request.serializedData(), videoRingFileHandle: videoProducer.descriptor.fileHandle,
        audioRingFileHandle: audioProducer.descriptor.fileHandle, outputFileHandle: output) {
        completeOnce(Self.replyResult($0))
      }
    } catch { completeOnce(.failure(error)) }
  }

  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    do {
      let format = try ProgramOutputMediaSampleConverter.h264Format(from: sampleBuffer)
      if lock.withLock({ !sentVideoFormat }) {
        try writeVideo(videoFormatRecord(format, sequence: nextVideoSequence()).serializedData())
        lock.withLock { sentVideoFormat = true }
      }
      try writeVideo(videoAccessUnitRecord(try ProgramOutputMediaSampleConverter.h264AccessUnit(from: sampleBuffer), sequence: nextVideoSequence()).serializedData())
    } catch { fail(error) }
  }

  func appendProgramAudio(_ packet: ProgramOutputAACPacket) {
    do {
      if lock.withLock({ !sentAudioFormat }) {
        try writeAudio(RecordingAACSampleConverter.formatRecord(from: packet.format, sequence: nextAudioSequence()).serializedData())
        lock.withLock { sentAudioFormat = true }
      }
      try writeAudio(RecordingAACSampleConverter.accessUnitRecord(from: packet.accessUnit, sequence: nextAudioSequence()).serializedData())
    } catch { fail(error) }
  }

  func finish(completionHandler: @escaping @Sendable (Result<Void, Error>) -> Void) {
    let connection = lock.withLock { () -> NSXPCConnection? in
      finishing = true
      generationFinishedReceived = false
      awaitingGenerationFinished = false
      pendingFinishCompletion = nil
      finishCompletionDelivered = false
      return self.connection
    }
    guard let connection,
      let service = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
        self?.finishFailed(error, completionHandler: completionHandler)
      }) as? LDTXRecordingWriterServiceXPC
    else { completionHandler(.success(())); return }
    service.drainMainRings { [weak self] data in
      let drainResult = Self.replyResult(data)
      guard case .success = drainResult else {
        self?.finishFailed(drainResult.failureValue, completionHandler: completionHandler)
        return
      }
      var request = Ldtx_Recording_Xpc_V1_FinishRequest()
      request.context.sessionID = "main"
      service.finish((try? request.serializedData()) ?? Data()) { data in
        self?.finishServiceReply(Self.replyResult(data), completionHandler: completionHandler)
      }
    }
  }

  func recordingWriterEvent(_ eventData: Data) {
    do {
      let event = try Ldtx_Recording_Xpc_V1_Event(serializedBytes: eventData)
      guard event.trackID == "main" else { return }
      switch event.kind {
      case .fragmentCommitted: trackRecorder.recordExternalFragment(event)
      case .generationFinished: finishGeneration(event)
      case .failed:
        let error = MainRecordingXPCClientError.serviceFailed(event.errorMessage)
        trackRecorder.markFailed(error); fail(error)
      default: break
      }
    } catch { fail(error) }
  }

  private func writeVideo(_ data: Data) throws { guard videoProducer.write(data) else { throw MainRecordingXPCClientError.ringOverflow("video") }; requestDrain() }
  private func writeAudio(_ data: Data) throws { guard audioProducer.write(data) else { throw MainRecordingXPCClientError.ringOverflow("audio") }; requestDrain() }
  private func requestDrain() {
    guard let service = lock.withLock({ connection })?.remoteObjectProxyWithErrorHandler({ [weak self] in self?.fail($0) }) as? LDTXRecordingWriterServiceXPC else { return }
    service.drainMainRings { [weak self] in if case .failure(let error) = Self.replyResult($0) { self?.fail(error) } }
  }
  private func videoFormatRecord(_ input: ProgramOutputH264Format, sequence: UInt64) -> Ldtx_Recording_Xpc_V1_VideoRingRecord {
    var format = Ldtx_Recording_Xpc_V1_H264Format(); format.parameterSets = input.parameterSets; format.nalUnitHeaderLength = input.nalUnitHeaderLength; format.width = input.width; format.height = input.height
    var record = Ldtx_Recording_Xpc_V1_VideoRingRecord(); record.sequence = sequence; record.format = format; return record
  }
  private func videoAccessUnitRecord(_ input: ProgramOutputH264AccessUnit, sequence: UInt64) -> Ldtx_Recording_Xpc_V1_VideoRingRecord {
    var unit = Ldtx_Recording_Xpc_V1_H264AccessUnit(); unit.presentationTime = mediaTime(input.presentationTime); unit.duration = mediaTime(input.duration); unit.keyFrame = input.isKeyFrame; unit.avccData = input.avccData
    if let decodeTime = input.decodeTime { unit.decodeTimePresent = true; unit.decodeTime = mediaTime(decodeTime) }
    var record = Ldtx_Recording_Xpc_V1_VideoRingRecord(); record.sequence = sequence; record.accessUnit = unit; return record
  }
  private func mediaTime(_ input: ProgramOutputMediaTime) -> Ldtx_Recording_Xpc_V1_MediaTime { var value = Ldtx_Recording_Xpc_V1_MediaTime(); value.value = input.value; value.timescale = input.timescale; return value }
  private func nextVideoSequence() -> UInt64 { lock.withLock { videoSequence += 1; return videoSequence } }
  private func nextAudioSequence() -> UInt64 { lock.withLock { audioSequence += 1; return audioSequence } }
  private func connectionFailed() { guard !lock.withLock({ finishing }) else { return }; fail(MainRecordingXPCClientError.connectionInterrupted) }

  private func finishServiceReply(
    _ result: Result<Void, Error>,
    completionHandler: @escaping @Sendable (Result<Void, Error>) -> Void
  ) {
    switch result {
    case .failure:
      finishFailed(result.failureValue, completionHandler: completionHandler)
    case .success:
      let completion = lock.withLock { () -> (@Sendable (Result<Void, Error>) -> Void)? in
        guard !finishCompletionDelivered else { return nil }
        awaitingGenerationFinished = true
        pendingFinishCompletion = completionHandler
        guard generationFinishedReceived else { return nil }
        return takeFinishCompletionLocked()
      }
      completion?(.success(()))
    }
  }

  private func finishGeneration(_ event: Ldtx_Recording_Xpc_V1_Event) {
    let completion = lock.withLock { () -> (@Sendable (Result<Void, Error>) -> Void)? in
      guard !finishCompletionDelivered else { return nil }
      generationFinishedReceived = true
      guard awaitingGenerationFinished else { return nil }
      return takeFinishCompletionLocked()
    }
    completion?(.success(()))
  }

  private func finishFailed(
    _ error: Error,
    completionHandler: @escaping @Sendable (Result<Void, Error>) -> Void
  ) {
    let completion = lock.withLock { () -> (@Sendable (Result<Void, Error>) -> Void)? in
      guard !finishCompletionDelivered else { return nil }
      if pendingFinishCompletion != nil { return takeFinishCompletionLocked() }
      finishCompletionDelivered = true
      return completionHandler
    }
    completion?(.failure(error))
  }

  private func takeFinishCompletionLocked() -> (@Sendable (Result<Void, Error>) -> Void)? {
    let completion = pendingFinishCompletion
    pendingFinishCompletion = nil
    awaitingGenerationFinished = false
    finishCompletionDelivered = true
    connection?.invalidate()
    connection = nil
    return completion
  }

  private func fail(_ error: Error) { guard !lock.withLock({ let was = failed; failed = true; return was }) else { return }; failureHandler(error) }
  private static func replyResult(_ data: Data) -> Result<Void, Error> { do { let reply = try Ldtx_Recording_Xpc_V1_Reply(serializedBytes: data); return reply.accepted ? .success(()) : .failure(MainRecordingXPCClientError.serviceFailed(reply.errorMessage)) } catch { return .failure(error) } }
}

private extension Result where Failure == Error {
  var failureValue: Error {
    guard case .failure(let error) = self else {
      preconditionFailure("Requested the failure value of a successful result.")
    }
    return error
  }
}

private enum MainRecordingXPCClientError: Error, LocalizedError {
  case missingServiceName, missingServiceProxy, ringOverflow(String), connectionInterrupted, serviceFailed(String)
  var errorDescription: String? { switch self { case .missingServiceName: "The Main Recording XPC service name is missing."; case .missingServiceProxy: "The Main Recording XPC proxy is unavailable."; case .ringOverflow(let track): "The Main Recording \(track) ring is full."; case .connectionInterrupted: "The Main Recording XPC connection stopped."; case .serviceFailed(let message): "The Main Recording XPC failed: \(message)" } }
}
