// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXMP4
import LDTXRecordingXPCProtocol
import SwiftProtobuf

private final class OutputVideoRecordingSession: @unchecked Sendable {
  private weak var connection: NSXPCConnection?
  private let lock = NSLock()
  private var context = Ldtx_Recording_Xpc_V1_Context()
  private var consumer: RecordingSharedRingConsumer?
  private var output: FileHandle?
  private var writer: H264PassthroughSegmentedMP4Writer?
  private var format: Ldtx_Recording_Xpc_V1_H264Format?
  private var byteOffset: UInt64 = 0

  init(connection: NSXPCConnection) {
    self.connection = connection
  }

  func configure(
    _ data: Data,
    ringFileHandle: FileHandle,
    outputFileHandle: FileHandle
  ) throws {
    let request = try Ldtx_Recording_Xpc_V1_ConfigureRequest(serializedBytes: data)
    guard request.protocolVersion == LDTXRecordingWriterXPCInterfaces.protocolVersion else {
      throw OutputVideoRecordingServiceError.incompatibleProtocol(request.protocolVersion)
    }
    let descriptor = RecordingSharedRingDescriptor(
      fileHandle: ringFileHandle,
      capacity: Int(request.ringCapacity),
      protocolVersion: RecordingSharedRingProducer.protocolVersion
    )
    let consumer = try RecordingSharedRingConsumer(descriptor: descriptor)
    let writer = try H264PassthroughSegmentedMP4Writer(
      segmentDurationSeconds: max(Int(request.segmentDurationSeconds), 1),
      onFailure: { [weak self] error in self?.sendFailure(error.localizedDescription) },
      onSegment: { [weak self] segment in self?.commit(segment) }
    )
    lock.withLock {
      context = request.context
      self.consumer = consumer
      output = outputFileHandle
      self.writer = writer
      format = nil
      byteOffset = 0
    }
  }

  func drain() throws {
    while let data = lock.withLock({ consumer?.read() }) {
      let record = try Ldtx_Recording_Xpc_V1_VideoRingRecord(serializedBytes: data)
      switch record.payload {
      case .format(let format):
        lock.withLock { self.format = format }
      case .accessUnit(let accessUnit):
        let values = lock.withLock { (format, writer) }
        guard let format = values.0, let writer = values.1 else {
          throw OutputVideoRecordingServiceError.missingFormat
        }
        writer.append(try RecordingH264SampleConverter.sampleBuffer(
          format: format,
          accessUnit: accessUnit
        ))
      case nil:
        continue
      }
    }
  }

  func finish(_ completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
    guard let writer = lock.withLock({ self.writer }) else {
      completion(.success(()))
      return
    }
    writer.finish { [weak self] result in
      if case .success = result {
        self?.lock.withLock {
          try? self?.output?.close()
          self?.output = nil
          self?.writer = nil
        }
        self?.sendEvent(kind: .generationFinished)
      }
      completion(result)
    }
  }

  private func commit(_ segment: SegmentedMP4Segment) {
    do {
      let committed = try lock.withLock { () -> (UInt64, Ldtx_Recording_Xpc_V1_Context) in
        guard let output else { throw OutputVideoRecordingServiceError.notConfigured }
        try output.write(contentsOf: segment.data)
        let offset = byteOffset
        byteOffset += UInt64(segment.data.count)
        return (offset, context)
      }
      var event = Ldtx_Recording_Xpc_V1_Event()
      event.context = committed.1
      event.kind = .fragmentCommitted
      event.trackID = "output-video"
      event.byteOffset = committed.0
      event.byteLength = UInt64(segment.data.count)
      if let value = segment.earliestPresentationTimeSeconds {
        event.presentationValue = Int64((value * 1_000_000).rounded())
        event.presentationTimescale = 1_000_000
      }
      if let value = segment.durationSeconds {
        event.durationValue = Int64((value * 1_000_000).rounded())
        event.durationTimescale = 1_000_000
      }
      send(event)
    } catch {
      sendFailure(error.localizedDescription)
    }
  }

  private func sendFailure(_ description: String) {
    var event = Ldtx_Recording_Xpc_V1_Event()
    event.context = lock.withLock { context }
    event.kind = .failed
    event.trackID = "output-video"
    event.errorMessage = description
    send(event)
  }

  private func sendEvent(kind: Ldtx_Recording_Xpc_V1_Event.Kind) {
    var event = Ldtx_Recording_Xpc_V1_Event()
    event.context = lock.withLock { context }
    event.kind = kind
    event.trackID = "output-video"
    send(event)
  }

  private func send(_ event: Ldtx_Recording_Xpc_V1_Event) {
    guard let proxy = connection?.remoteObjectProxy as? LDTXRecordingWriterClientXPC,
      let data = try? event.serializedData()
    else { return }
    proxy.recordingWriterEvent(data)
  }
}

private enum OutputVideoRecordingServiceError: Error {
  case incompatibleProtocol(UInt32)
  case missingFormat
  case notConfigured
}

private final class OutputVideoRecordingConnection: NSObject, LDTXRecordingWriterServiceXPC,
  @unchecked Sendable
{
  private let session: OutputVideoRecordingSession

  init(connection: NSXPCConnection) {
    session = OutputVideoRecordingSession(connection: connection)
  }

  func configure(
    _ request: Data,
    ringFileHandle: FileHandle,
    outputFileHandle: FileHandle,
    withReply reply: @escaping (Data) -> Void
  ) {
    reply(response { try session.configure(
      request,
      ringFileHandle: ringFileHandle,
      outputFileHandle: outputFileHandle
    ) })
  }

  func drainRing(withReply reply: @escaping (Data) -> Void) {
    reply(response { try session.drain() })
  }

  func prepareCut(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    reply(response {})
  }

  func commitCut(
    _ request: Data,
    outputFileHandle: FileHandle,
    withReply reply: @escaping (Data) -> Void
  ) {
    reply(response {})
  }

  func finish(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let reply = OutputVideoRecordingReply(reply)
    session.finish { [self] result in reply.call(response { try result.get() }) }
  }

  func abort(_ request: Data) {}

  func status(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    reply(response {})
  }

  private func response(_ operation: () throws -> Void) -> Data {
    var response = Ldtx_Recording_Xpc_V1_Reply()
    do {
      try operation()
      response.accepted = true
    } catch {
      response.errorMessage = error.localizedDescription
    }
    return (try? response.serializedData()) ?? Data()
  }
}

private final class OutputVideoRecordingReply: @unchecked Sendable {
  private let body: (Data) -> Void

  init(_ body: @escaping (Data) -> Void) {
    self.body = body
  }

  func call(_ data: Data) {
    body(data)
  }
}

private final class OutputVideoRecordingListenerDelegate: NSObject, NSXPCListenerDelegate {
  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    connection.exportedInterface = LDTXRecordingWriterXPCInterfaces.service()
    connection.remoteObjectInterface = LDTXRecordingWriterXPCInterfaces.client()
    connection.exportedObject = OutputVideoRecordingConnection(connection: connection)
    connection.resume()
    return true
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

private let listener = NSXPCListener.service()
private let delegate = OutputVideoRecordingListenerDelegate()
listener.delegate = delegate
listener.resume()
