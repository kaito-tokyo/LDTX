// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public actor YouTubeRTMPSPublisher {
  public typealias StateHandler = @Sendable (YouTubeRTMPSPublisherState) -> Void

  public private(set) var state: YouTubeRTMPSPublisherState = .idle
  private let transport: any RTMPTransport
  private let stateHandler: StateHandler
  private var chunkEncoder = RTMPChunkEncoder(chunkSize: 4_096)
  private var destination: YouTubeRTMPSDestination?
  private var videoFormat: YouTubeRTMPSVideoFormat?
  private var audioFormat: YouTubeRTMPSAudioFormat?
  private var sentVideoHeader = false
  private var sentAudioHeader = false
  private var bytesReceived: UInt32 = 0
  private var acknowledgementWindow: UInt32 = 2_500_000
  private var messageStreamID: UInt32 = 0
  private var controlTask: Task<Void, Never>?
  private let reconnectDelays: [Duration]

  public init(stateHandler: @escaping StateHandler = { _ in }) {
    transport = NetworkRTMPTransport()
    self.stateHandler = stateHandler
    reconnectDelays = [.milliseconds(250), .seconds(1), .seconds(2)]
  }

  init(
    transport: any RTMPTransport,
    reconnectDelays: [Duration] = [],
    stateHandler: @escaping StateHandler = { _ in }
  ) {
    self.transport = transport
    self.stateHandler = stateHandler
    self.reconnectDelays = reconnectDelays
  }

  public func connect(
    to destination: YouTubeRTMPSDestination,
    videoFormat: YouTubeRTMPSVideoFormat,
    audioFormat: YouTubeRTMPSAudioFormat
  ) async throws {
    guard state == .idle || state == .stopped else {
      throw YouTubeRTMPSError.protocolFailure("start")
    }
    self.destination = destination
    self.videoFormat = videoFormat
    self.audioFormat = audioFormat
    sentVideoHeader = false
    sentAudioHeader = false
    setState(.connecting)
    do {
      try await establish(destination)
      setState(.publishing)
      startControlReader()
    } catch {
      await transport.close()
      clearSession()
      setState(.stopped)
      throw sanitized(error)
    }
  }

  public func appendVideo(_ sample: YouTubeRTMPSVideoSample) async throws {
    if case .reconnecting = state {
      guard sample.isKeyFrame else { return }
      try await reconnect()
    }
    guard state == .publishing, let videoFormat else { throw YouTubeRTMPSError.notPublishing }
    if !sentVideoHeader {
      let header = try FLVPacketEncoder.avcSequenceHeader(videoFormat)
      do {
        try await send(header)
      } catch {
        try await beginReconnect()
        return
      }
      sentVideoHeader = true
    }
    let packet = try FLVPacketEncoder.video(sample)
    do {
      try await send(packet)
    } catch {
      try await beginReconnect()
    }
  }

  public func appendAudio(_ sample: YouTubeRTMPSAudioSample) async throws {
    if case .reconnecting = state { return }
    guard state == .publishing, let audioFormat else { throw YouTubeRTMPSError.notPublishing }
    if !sentAudioHeader {
      let header = FLVPacketEncoder.aacSequenceHeader(audioFormat)
      do {
        try await send(header)
      } catch {
        try await beginReconnect()
        return
      }
      sentAudioHeader = true
    }
    let packet = try FLVPacketEncoder.audio(sample)
    do {
      try await send(packet)
    } catch {
      try await beginReconnect()
    }
  }

  public func finish() async {
    controlTask?.cancel()
    controlTask = nil
    if state == .publishing {
      let command = AMF0Encoder.encode([
        .string("deleteStream"), .number(0), .null, .number(Double(messageStreamID)),
      ])
      try? await transport.send(
        chunkEncoder.encode(
          chunkStreamID: 3, messageTypeID: 20, messageStreamID: 0,
          timestamp: 0, payload: command))
    }
    await transport.close()
    clearSession()
    setState(.stopped)
  }

  private func establish(_ destination: YouTubeRTMPSDestination) async throws {
    guard let host = destination.ingestionURL.host else {
      throw YouTubeRTMPSError.invalidDestination
    }
    try await transport.connect(host: host, port: UInt16(destination.ingestionURL.port ?? 443))
    try await handshake()
    try await setOutboundChunkSize()
    let app = destination.ingestionURL.path.split(separator: "/").first.map(String.init) ?? "live2"
    try await command(
      "connect", transaction: 1, streamID: 0,
      arguments: [
        .object([
          ("app", .string(app)),
          ("type", .string("nonprivate")),
          ("tcUrl", .string(destination.ingestionURL.absoluteString)),
          ("flashVer", .string("FMLE/3.0 (compatible; LDTX)")),
          ("fpad", .boolean(false)),
          ("capabilities", .number(15)),
          ("audioCodecs", .number(0x0400)),
          ("videoCodecs", .number(0x0080)),
          ("videoFunction", .number(1)),
        ])
      ])
    _ = try await waitFor("_result", phase: "connect")
    try await command(
      "releaseStream", transaction: 2, streamID: 0,
      arguments: [.null, .string(destination.streamName)])
    try await command(
      "FCPublish", transaction: 3, streamID: 0,
      arguments: [.null, .string(destination.streamName)])
    try await command("createStream", transaction: 4, streamID: 0, arguments: [.null])
    let createStreamResponse = try await waitFor("_result", phase: "createStream")
    messageStreamID = try Self.createdStreamID(in: createStreamResponse)
    try await command(
      "publish", transaction: 0, streamID: messageStreamID,
      arguments: [.null, .string(destination.streamName), .string("live")])
    _ = try await waitFor("NetStream.Publish.Start", phase: "publish")
  }

  private func beginReconnect() async throws {
    controlTask?.cancel()
    controlTask = nil
    await transport.close()
    sentVideoHeader = false
    sentAudioHeader = false
    setState(.reconnecting(attempt: 0))
    if reconnectDelays.isEmpty {
      clearSession()
      setState(.stopped)
      throw YouTubeRTMPSError.connectionFailed
    }
  }

  private func reconnect() async throws {
    guard let destination else { throw YouTubeRTMPSError.connectionFailed }
    for (index, delay) in reconnectDelays.enumerated() {
      setState(.reconnecting(attempt: index + 1))
      try await Task.sleep(for: delay)
      do {
        bytesReceived = 0
        try await establish(destination)
        setState(.publishing)
        startControlReader()
        return
      } catch {
        await transport.close()
      }
    }
    clearSession()
    setState(.stopped)
    throw YouTubeRTMPSError.connectionFailed
  }

  private func handshake() async throws {
    var c0c1 = Data([3])
    c0c1.appendUInt32(UInt32(Date().timeIntervalSince1970))
    c0c1.appendUInt32(0)
    var random = SystemRandomNumberGenerator()
    for _ in 0..<1_528 { c0c1.append(UInt8.random(in: .min ... .max, using: &random)) }
    try await transport.send(c0c1)
    let response = try await receiveExactly(3_073)
    guard response.first == 3 else { throw YouTubeRTMPSError.protocolFailure("handshake") }
    try await transport.send(response.subdata(in: 1..<1_537))
  }

  private func setOutboundChunkSize() async throws {
    var payload = Data()
    payload.appendUInt32(UInt32(chunkEncoder.chunkSize))
    try await transport.send(
      RTMPChunkEncoder().encode(
        chunkStreamID: 2, messageTypeID: 1, messageStreamID: 0,
        timestamp: 0, payload: payload))
  }

  private func command(
    _ name: String, transaction: Double, streamID: UInt32, arguments: [AMF0Value]
  ) async throws {
    let payload = AMF0Encoder.encode([.string(name), .number(transaction)] + arguments)
    try await transport.send(
      chunkEncoder.encode(
        chunkStreamID: streamID == 0 ? 3 : 8, messageTypeID: 20,
        messageStreamID: streamID, timestamp: 0, payload: payload))
  }

  private func send(_ packet: FLVPacket) async throws {
    do {
      try await transport.send(
        chunkEncoder.encode(
          chunkStreamID: packet.typeID == 9 ? 6 : 4,
          messageTypeID: packet.typeID,
          messageStreamID: messageStreamID,
          timestamp: packet.timestamp,
          payload: packet.payload))
    } catch {
      throw sanitized(error)
    }
  }

  private func waitFor(_ marker: String, phase: String) async throws -> Data {
    let needle = Data(marker.utf8)
    var buffered = Data()
    while buffered.count < 1_048_576 {
      let data = try await transport.receive(minimum: 1, maximum: 65_536)
      bytesReceived &+= UInt32(clamping: data.count)
      buffered.append(data)
      try await handleControlMessages(in: data)
      if buffered.range(of: needle) != nil { return buffered }
    }
    throw YouTubeRTMPSError.protocolFailure(phase)
  }

  private func startControlReader() {
    controlTask?.cancel()
    controlTask = Task { [weak self] in await self?.readControlMessages() }
  }

  private func readControlMessages() async {
    do {
      while !Task.isCancelled, state == .publishing {
        let data = try await transport.receive(minimum: 1, maximum: 65_536)
        bytesReceived &+= UInt32(clamping: data.count)
        try await handleControlMessages(in: data)
        if data.range(of: Data("NetStream.Publish".utf8)) != nil,
          data.range(of: Data("NetStream.Publish.Start".utf8)) == nil
        {
          throw YouTubeRTMPSError.protocolFailure("publish")
        }
      }
    } catch {
      guard !Task.isCancelled, state == .publishing else { return }
      try? await beginReconnect()
    }
  }

  private func handleControlMessages(in data: Data) async throws {
    if let window = Self.windowAcknowledgementSize(in: data) {
      acknowledgementWindow = max(window, 1)
    }
    if let pingTimestamp = Self.pingRequest(in: data) {
      var pong = Data([0, 7])
      pong.appendUInt32(pingTimestamp)
      try await transport.send(
        chunkEncoder.encode(
          chunkStreamID: 2, messageTypeID: 4, messageStreamID: 0,
          timestamp: 0, payload: pong))
    }
    if bytesReceived >= acknowledgementWindow {
      var acknowledgement = Data()
      acknowledgement.appendUInt32(bytesReceived)
      try await transport.send(
        chunkEncoder.encode(
          chunkStreamID: 2, messageTypeID: 3, messageStreamID: 0,
          timestamp: 0, payload: acknowledgement))
      bytesReceived = 0
    }
  }

  private static func createdStreamID(in data: Data) throws -> UInt32 {
    let marker = Data([2, 0, 7]) + Data("_result".utf8)
    guard let markerRange = data.range(of: marker) else {
      throw YouTubeRTMPSError.protocolFailure("createStream")
    }
    var offset = markerRange.upperBound
    guard data.count >= offset + 9, data[offset] == 0 else {
      throw YouTubeRTMPSError.protocolFailure("createStream")
    }
    offset += 9
    guard data.count > offset, data[offset] == 5 else {
      throw YouTubeRTMPSError.protocolFailure("createStream")
    }
    offset += 1
    guard data.count >= offset + 9, data[offset] == 0 else {
      throw YouTubeRTMPSError.protocolFailure("createStream")
    }
    let bits = data[(offset + 1)..<(offset + 9)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    let value = Double(bitPattern: bits)
    guard value.isFinite, value >= 1, value <= Double(UInt32.max), value.rounded() == value else {
      throw YouTubeRTMPSError.protocolFailure("createStream")
    }
    return UInt32(value)
  }

  private func clearSession() {
    controlTask?.cancel()
    controlTask = nil
    destination = nil
    videoFormat = nil
    audioFormat = nil
    messageStreamID = 0
    sentVideoHeader = false
    sentAudioHeader = false
    bytesReceived = 0
  }

  private func receiveExactly(_ count: Int) async throws -> Data {
    var data = Data()
    while data.count < count {
      data.append(try await transport.receive(minimum: 1, maximum: count - data.count))
    }
    return data
  }

  private static func windowAcknowledgementSize(in data: Data) -> UInt32? {
    guard data.count >= 16, data[7] == 5 else { return nil }
    return data.readUInt32(at: 12)
  }

  private static func pingRequest(in data: Data) -> UInt32? {
    guard data.count >= 18, data[7] == 4, data[12] == 0, data[13] == 6 else { return nil }
    return data.readUInt32(at: 14)
  }

  private func setState(_ value: YouTubeRTMPSPublisherState) {
    state = value
    stateHandler(value)
  }

  private func sanitized(_ error: any Error) -> YouTubeRTMPSError {
    if let error = error as? YouTubeRTMPSError { return error }
    return .connectionFailed
  }
}

extension Data {
  fileprivate func readUInt32(at offset: Int) -> UInt32? {
    guard offset >= 0, count >= offset + 4 else { return nil }
    return self[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
  }
}
