// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXRecordingXPCProtocol
import SwiftProtobuf

final class RecordingWriterXPCClient: NSObject, LDTXRecordingWriterClientXPC,
  @unchecked Sendable
{
  enum MediaKind: Sendable, Equatable {
    case video
    case audio

    var capacity: Int {
      switch self {
      case .video: 16 * 1_024 * 1_024
      case .audio: 8 * 1_024 * 1_024
      }
    }
  }

  private let lock = NSLock()
  private let mediaKind: MediaKind
  private let serviceName: String
  private let trackID: String
  private let trackRecorder: HLSByteRangeTrackRecorder
  private let segmentDurationSeconds: Int
  private let failureHandler: @Sendable (Error) -> Void
  private let producer: RecordingSharedRingProducer
  private var connection: NSXPCConnection?
  private var sequence: UInt64 = 0
  private var sentFormat = false
  private var finishing = false

  init(
    mediaKind: MediaKind,
    serviceSuffix: String,
    serviceName explicitServiceName: String? = nil,
    trackID: String,
    trackRecorder: HLSByteRangeTrackRecorder,
    segmentDurationSeconds: Int,
    failureHandler: @escaping @Sendable (Error) -> Void
  ) throws {
    self.mediaKind = mediaKind
    if let explicitServiceName {
      serviceName = explicitServiceName
    } else {
      let infoKey = "LDTX\(serviceSuffix)XPCServiceName"
      guard
        let configuredServiceName = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
        !configuredServiceName.isEmpty
      else { throw RecordingWriterXPCClientError.missingServiceName(infoKey) }
      serviceName = configuredServiceName
    }
    self.trackID = trackID
    self.trackRecorder = trackRecorder
    self.segmentDurationSeconds = segmentDurationSeconds
    self.failureHandler = failureHandler
    producer = try RecordingSharedRingProducer.create(capacity: mediaKind.capacity)
    super.init()
  }

  func start(
    sessionID: String,
    generation: UInt64 = 1,
    completionHandler: @escaping @Sendable (Result<Void, Error>) -> Void
  ) {
    let connection = NSXPCConnection(serviceName: serviceName)
    connection.remoteObjectInterface = LDTXRecordingWriterXPCInterfaces.service()
    connection.exportedInterface = LDTXRecordingWriterXPCInterfaces.client()
    connection.exportedObject = self
    connection.interruptionHandler = { [weak self] in self?.connectionFailed() }
    connection.invalidationHandler = { [weak self] in self?.connectionFailed() }
    connection.resume()
    lock.withLock { self.connection = connection }

    do {
      var request = Ldtx_Recording_Xpc_V1_ConfigureRequest()
      request.protocolVersion = LDTXRecordingWriterXPCInterfaces.protocolVersion
      request.context.sessionID = sessionID
      request.context.generation = generation
      request.trackID = trackID
      request.ringCapacity = UInt64(mediaKind.capacity)
      request.segmentDurationSeconds = UInt32(segmentDurationSeconds)
      let requestData = try request.serializedData()
      let output = try trackRecorder.makeOutputFileHandle()
      guard
        let service = connection.remoteObjectProxyWithErrorHandler({ error in
          completionHandler(.failure(error))
        }) as? LDTXRecordingWriterServiceXPC
      else {
        throw RecordingWriterXPCClientError.missingServiceProxy
      }
      service.configure(
        requestData,
        ringFileHandle: producer.descriptor.fileHandle,
        outputFileHandle: output
      ) { data in
        completionHandler(Self.replyResult(data))
      }
    } catch {
      completionHandler(.failure(error))
    }
  }

  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    guard mediaKind == .video else { return }
    do {
      if lock.withLock({ !sentFormat }) {
        try write(
          RecordingH264SampleConverter.formatRecord(
            from: sampleBuffer, sequence: nextSequence()
          ).serializedData())
        lock.withLock { sentFormat = true }
      }
      try write(
        RecordingH264SampleConverter.accessUnitRecord(
          from: sampleBuffer, sequence: nextSequence()
        ).serializedData())
    } catch {
      failureHandler(error)
    }
  }

  func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    guard mediaKind == .audio else { return }
    trackRecorder.notePresentationStart(sampleBuffer.presentationTimeStamp)
    do {
      if lock.withLock({ !sentFormat }) {
        try write(
          RecordingPCMSampleConverter.formatRecord(
            from: sampleBuffer, sequence: nextSequence()
          ).serializedData())
        lock.withLock { sentFormat = true }
      }
      try write(
        RecordingPCMSampleConverter.bufferRecord(
          from: sampleBuffer, sequence: nextSequence()
        ).serializedData())
    } catch {
      failureHandler(error)
    }
  }

  func finish(completionHandler: @escaping @Sendable (Result<Void, Error>) -> Void) {
    let connection = lock.withLock { () -> NSXPCConnection? in
      finishing = true
      return self.connection
    }
    guard let connection,
      let service = connection.remoteObjectProxyWithErrorHandler({ error in
        completionHandler(.failure(error))
      }) as? LDTXRecordingWriterServiceXPC
    else {
      completionHandler(.success(()))
      return
    }
    var request = Ldtx_Recording_Xpc_V1_FinishRequest()
    request.context.sessionID = trackID
    service.finish((try? request.serializedData()) ?? Data()) { [weak self] data in
      let result = Self.replyResult(data)
      self?.lock.withLock {
        self?.connection?.invalidate()
        self?.connection = nil
      }
      completionHandler(result)
    }
  }

  func recordingWriterEvent(_ eventData: Data) {
    do {
      let event = try Ldtx_Recording_Xpc_V1_Event(serializedBytes: eventData)
      guard event.trackID == trackID else { return }
      switch event.kind {
      case .fragmentCommitted:
        trackRecorder.recordExternalFragment(event)
      case .failed:
        let error = RecordingWriterXPCClientError.serviceFailed(event.errorMessage)
        trackRecorder.markFailed(error)
        failureHandler(error)
      default:
        break
      }
    } catch {
      failureHandler(error)
    }
  }

  private func write(_ data: Data) throws {
    guard producer.write(data) else {
      throw RecordingWriterXPCClientError.ringOverflow(trackID)
    }
    guard
      let service = lock.withLock({ connection })?.remoteObjectProxyWithErrorHandler({
        [weak self] error in self?.failureHandler(error)
      }) as? LDTXRecordingWriterServiceXPC
    else {
      throw RecordingWriterXPCClientError.missingServiceProxy
    }
    service.drainRing { [weak self] data in
      if case .failure(let error) = Self.replyResult(data) {
        self?.failureHandler(error)
      }
    }
  }

  private func nextSequence() -> UInt64 {
    lock.withLock {
      sequence += 1
      return sequence
    }
  }

  private func connectionFailed() {
    guard !lock.withLock({ finishing }) else { return }
    let error = RecordingWriterXPCClientError.connectionInterrupted(trackID)
    trackRecorder.markFailed(error)
    failureHandler(error)
  }

  private static func replyResult(_ data: Data) -> Result<Void, Error> {
    do {
      let reply = try Ldtx_Recording_Xpc_V1_Reply(serializedBytes: data)
      guard reply.accepted else {
        return .failure(RecordingWriterXPCClientError.serviceFailed(reply.errorMessage))
      }
      return .success(())
    } catch {
      return .failure(error)
    }
  }
}

enum RecordingWriterXPCClientError: Error, LocalizedError {
  case missingServiceName(String)
  case missingServiceProxy
  case ringOverflow(String)
  case connectionInterrupted(String)
  case serviceFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingServiceName(let key): "The recording XPC service name is missing for \(key)."
    case .missingServiceProxy: "The recording XPC service proxy is unavailable."
    case .ringOverflow(let track): "The recording ring is full for \(track)."
    case .connectionInterrupted(let track): "The recording XPC connection stopped for \(track)."
    case .serviceFailed(let reason): "The recording XPC service failed: \(reason)"
    }
  }
}
