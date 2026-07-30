// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXMP4
import LDTXRecordingXPCProtocol
import SwiftProtobuf

private final class MainRecordingSession: @unchecked Sendable {
  private static let maximumPendingVideoSamples = 360
  private static let maximumPendingAudioSamples = 512
  private weak var connection: NSXPCConnection?
  private let lock = NSLock()
  /// XPC may deliver multiple drain requests concurrently.  Ring consumption,
  /// sample ordering and the non-thread-safe mux writer form one operation.
  private let writerQueue = DispatchQueue(label: "tokyo.kaito.ldtx.main-recording.writer")
  private var context = Ldtx_Recording_Xpc_V1_Context()
  private var videoConsumer: RecordingSharedRingConsumer?
  private var audioConsumer: RecordingSharedRingConsumer?
  private var output: FileHandle?
  private var videoFormat: Ldtx_Recording_Xpc_V1_H264Format?
  private var audioFormat: Ldtx_Recording_Xpc_V1_AACFormat?
  private var writer: MuxedPassthroughSegmentedMP4Writer?
  private var pendingVideo: [CMSampleBuffer] = []
  private var pendingAudio: [CMSampleBuffer] = []
  private var segmentDurationSeconds = 2
  private var byteOffset: UInt64 = 0

  init(connection: NSXPCConnection) { self.connection = connection }

  func configure(_ data: Data, video: FileHandle, audio: FileHandle, output: FileHandle) throws {
    try writerQueue.sync {
      try configureLocked(data, video: video, audio: audio, output: output)
    }
  }

  private func configureLocked(_ data: Data, video: FileHandle, audio: FileHandle, output: FileHandle) throws {
    let request = try Ldtx_Recording_Xpc_V1_MainConfigureRequest(serializedBytes: data)
    guard request.protocolVersion == LDTXRecordingWriterXPCInterfaces.protocolVersion else { throw MainRecordingServiceError.incompatibleProtocol }
    let videoDescriptor = RecordingSharedRingDescriptor(fileHandle: video, capacity: Int(request.videoRingCapacity), protocolVersion: RecordingSharedRingProducer.protocolVersion)
    let audioDescriptor = RecordingSharedRingDescriptor(fileHandle: audio, capacity: Int(request.audioRingCapacity), protocolVersion: RecordingSharedRingProducer.protocolVersion)
    lock.withLock {
      context = request.context
      videoConsumer = try? RecordingSharedRingConsumer(descriptor: videoDescriptor)
      audioConsumer = try? RecordingSharedRingConsumer(descriptor: audioDescriptor)
      self.output = output; videoFormat = nil; audioFormat = nil; writer = nil
      pendingVideo.removeAll(keepingCapacity: false); pendingAudio.removeAll(keepingCapacity: false)
      segmentDurationSeconds = max(Int(request.segmentDurationSeconds), 1); byteOffset = 0
    }
    guard lock.withLock({ videoConsumer != nil && audioConsumer != nil }) else { throw MainRecordingServiceError.invalidRing }
  }

  func drain() throws {
    try writerQueue.sync { try drainLocked() }
  }

  private func drainLocked() throws {
    var video: [CMSampleBuffer] = []
    var audio: [CMSampleBuffer] = []
    while let bytes = lock.withLock({ videoConsumer?.read() }) {
      let record = try Ldtx_Recording_Xpc_V1_VideoRingRecord(serializedBytes: bytes)
      switch record.payload {
      case .format(let value): lock.withLock { videoFormat = value }
      case .accessUnit(let unit):
        guard let format = lock.withLock({ videoFormat }) else { throw MainRecordingServiceError.missingVideoFormat }
        video.append(try RecordingH264SampleConverter.sampleBuffer(format: format, accessUnit: unit))
      case nil: break
      }
    }
    while let bytes = lock.withLock({ audioConsumer?.read() }) {
      let record = try Ldtx_Recording_Xpc_V1_AACRingRecord(serializedBytes: bytes)
      switch record.payload {
      case .format(let value): lock.withLock { audioFormat = value }
      case .accessUnit(let unit):
        guard let format = lock.withLock({ audioFormat }) else { throw MainRecordingServiceError.missingAudioFormat }
        audio.append(try RecordingAACSampleConverter.sampleBuffer(format: format, accessUnit: unit))
      case nil: break
      }
    }
    let ready = try lock.withLock { () throws -> (MuxedPassthroughSegmentedMP4Writer?, [CMSampleBuffer], [CMSampleBuffer]) in
      if writer == nil {
        guard
          pendingVideo.count + video.count <= Self.maximumPendingVideoSamples,
          pendingAudio.count + audio.count <= Self.maximumPendingAudioSamples
        else { throw MainRecordingServiceError.pendingCapacityExceeded }
        pendingVideo.append(contentsOf: video)
        pendingAudio.append(contentsOf: audio)
        try createWriterIfPossibleLocked()
        guard let writer else { return (nil, [], []) }
        let video = pendingVideo; let audio = pendingAudio
        pendingVideo.removeAll(keepingCapacity: false); pendingAudio.removeAll(keepingCapacity: false)
        return (writer, video, audio)
      }
      return (writer, video, audio)
    }
    ready.0?.append(video: ready.1, audio: ready.2)
  }

  private func createWriterIfPossibleLocked() throws {
    guard writer == nil,
      let firstSyncVideoIndex = pendingVideo.firstIndex(where: Self.isSyncVideo),
      let videoDescription = pendingVideo[firstSyncVideoIndex].formatDescription,
      let audioDescription = pendingAudio.first?.formatDescription
    else { return }
    // AVAssetWriter must begin a fragmented H.264 stream on a random-access
    // sample.  The two producer rings are independent, so AAC can arrive
    // before the first encoded keyframe and the video ring can start in the
    // middle of a GOP.  Keep buffering until a sync sample, then make that
    // sample the recording origin and discard the undecodable prefix.
    let origin = pendingVideo[firstSyncVideoIndex].presentationTimeStamp
    pendingVideo.removeFirst(firstSyncVideoIndex)
    pendingAudio.removeAll {
      CMTimeCompare($0.presentationTimeStamp, origin) < 0
    }
    writer = try MuxedPassthroughSegmentedMP4Writer(videoFormatDescription: videoDescription, audioFormatDescription: audioDescription,
      segmentDurationSeconds: segmentDurationSeconds, onFailure: { [weak self] in self?.sendFailure($0.localizedDescription) }, onSegment: { [weak self] segment in
        // All fragment notifications and the terminal generation event leave
        // this serial queue.  The client therefore treats generationFinished
        // as a watermark: every preceding durable fragment is in its ledger
        // before it may finalize the recording package.
        guard let session = self else { return }
        session.writerQueue.async { [weak session] in
          session?.commit(segment)
        }
      })
  }

  private static func isSyncVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
      let attachment = attachments.first
    else { return true }
    return (attachment[kCMSampleAttachmentKey_NotSync] as? Bool) != true
  }

  func finish(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    do {
      try writerQueue.sync { try drainLocked() }
    } catch { completion(.failure(error)); return }
    guard let writer = lock.withLock({ self.writer }) else {
      writerQueue.async { [weak self] in
        self?.send(kind: .generationFinished)
        completion(.success(()))
      }
      return
    }
    writer.finish { [weak self] result in
      // MuxedPassthroughSegmentedMP4Writer invokes this after its own queue
      // has drained.  Re-enter writerQueue so the terminal notification is
      // ordered after every queued fragment commit.
      guard let session = self else { return }
      session.writerQueue.async { [weak session] in
        guard let session else { return }
        if case .success = result {
          session.closeOutput()
          session.send(kind: .generationFinished)
        }
        completion(result)
      }
    }
  }

  private func closeOutput() {
    lock.withLock {
      try? output?.close()
      output = nil
    }
  }

  private func commit(_ segment: SegmentedMP4Segment) {
    do {
      let value = try lock.withLock { () -> (UInt64, Ldtx_Recording_Xpc_V1_Context) in
        guard let output else { throw MainRecordingServiceError.notConfigured }
        try output.write(contentsOf: segment.data); let offset = byteOffset; byteOffset += UInt64(segment.data.count); return (offset, context)
      }
      var event = Ldtx_Recording_Xpc_V1_Event(); event.context = value.1; event.kind = .fragmentCommitted; event.trackID = "main"; event.byteOffset = value.0; event.byteLength = UInt64(segment.data.count)
      event.fragmentKind = segment.kind == .initialization ? .initialization : .media
      if let time = segment.earliestPresentationTimeSeconds { event.presentationValue = Int64((time * 1_000_000).rounded()); event.presentationTimescale = 1_000_000 }
      if let duration = segment.durationSeconds { event.durationValue = Int64((duration * 1_000_000).rounded()); event.durationTimescale = 1_000_000 }
      send(event)
    } catch { sendFailure(error.localizedDescription) }
  }
  private func sendFailure(_ message: String) { var event = Ldtx_Recording_Xpc_V1_Event(); event.context = lock.withLock { context }; event.kind = .failed; event.trackID = "main"; event.errorMessage = message; send(event) }
  private func send(kind: Ldtx_Recording_Xpc_V1_Event.Kind) { var event = Ldtx_Recording_Xpc_V1_Event(); event.context = lock.withLock { context }; event.kind = kind; event.trackID = "main"; send(event) }
  private func send(_ event: Ldtx_Recording_Xpc_V1_Event) { guard let proxy = connection?.remoteObjectProxy as? LDTXRecordingWriterClientXPC, let data = try? event.serializedData() else { return }; proxy.recordingWriterEvent(data) }
}

private enum MainRecordingServiceError: Error {
  case incompatibleProtocol
  case invalidRing
  case missingVideoFormat
  case missingAudioFormat
  case notConfigured
  case pendingCapacityExceeded
}

private final class MainRecordingConnection: NSObject, LDTXRecordingWriterServiceXPC, @unchecked Sendable {
  private let session: MainRecordingSession
  init(connection: NSXPCConnection) { session = MainRecordingSession(connection: connection) }
  func configureMain(_ request: Data, videoRingFileHandle: FileHandle, audioRingFileHandle: FileHandle, outputFileHandle: FileHandle, withReply reply: @escaping (Data) -> Void) { reply(response { try session.configure(request, video: videoRingFileHandle, audio: audioRingFileHandle, output: outputFileHandle) }) }
  func drainMainRings(withReply reply: @escaping (Data) -> Void) { reply(response { try session.drain() }) }
  func finish(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let reply = MainRecordingReply(reply)
    session.finish { result in
      reply.call(self.response { try result.get() })
    }
  }
  private func response(_ operation: () throws -> Void) -> Data { var reply = Ldtx_Recording_Xpc_V1_Reply(); do { try operation(); reply.accepted = true } catch { reply.errorMessage = error.localizedDescription }; return (try? reply.serializedData()) ?? Data() }
}
private final class MainRecordingReply: @unchecked Sendable {
  private let body: (Data) -> Void
  init(_ body: @escaping (Data) -> Void) { self.body = body }
  func call(_ data: Data) { body(data) }
}
private final class MainRecordingListener: NSObject, NSXPCListenerDelegate { func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool { connection.exportedInterface = LDTXRecordingWriterXPCInterfaces.service(); connection.remoteObjectInterface = LDTXRecordingWriterXPCInterfaces.client(); connection.exportedObject = MainRecordingConnection(connection: connection); connection.resume(); return true } }
extension NSLock { fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() } }
private let listener = NSXPCListener.service(); private let delegate = MainRecordingListener(); listener.delegate = delegate; listener.resume()
