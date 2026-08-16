// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXYouTubeRTMPS

struct YouTubeRTMPSPublisherTests {
  @Test func performsHandshakeAndPublishWithoutExposingDestination() async throws {
    let transport = MockRTMPTransport()
    let publisher = YouTubeRTMPSPublisher(transport: transport)
    try await publisher.connect(
      to: destination("landscape-secret"),
      videoFormat: videoFormat,
      audioFormat: audioFormat)
    #expect(await publisher.state == .publishing)
    let writes = await transport.writes
    #expect(writes.first?.first == 3)
    #expect(writes.contains { $0.range(of: Data("landscape-secret".utf8)) != nil })
    let publish = try #require(writes.first { $0.range(of: Data("publish".utf8)) != nil })
    #expect(Array(publish[8..<12]) == [7, 0, 0, 0])
    #expect(String(describing: publisher).contains("landscape-secret") == false)
    await publisher.finish()
  }

  @Test func sendsCodecHeadersBeforeMedia() async throws {
    let transport = MockRTMPTransport()
    let publisher = YouTubeRTMPSPublisher(transport: transport)
    try await publisher.connect(
      to: destination("secret"), videoFormat: videoFormat, audioFormat: audioFormat)
    let baseline = await transport.writes.count
    try await publisher.appendVideo(
      YouTubeRTMPSVideoSample(
        avccData: Data([0, 0, 0, 1, 0x65]),
        presentationTime: .init(milliseconds: 0),
        decodeTime: .init(milliseconds: 0), isKeyFrame: true))
    try await publisher.appendAudio(
      YouTubeRTMPSAudioSample(rawAACData: Data([1]), presentationTime: .init(milliseconds: 0)))
    #expect(await transport.writes.count == baseline + 4)
    await publisher.finish()
  }

  @Test func reconnectsAtNextKeyFrameWithoutBufferingMedia() async throws {
    let transport = MockRTMPTransport()
    let publisher = YouTubeRTMPSPublisher(
      transport: transport, reconnectDelays: [.zero])
    try await publisher.connect(
      to: destination("secret"), videoFormat: videoFormat, audioFormat: audioFormat)
    await transport.failNextWriteAndPrepareReconnect()
    try await publisher.appendVideo(videoSample(keyFrame: false, timestamp: 1))
    #expect(await publisher.state == .reconnecting(attempt: 0))
    try await publisher.appendAudio(
      YouTubeRTMPSAudioSample(rawAACData: Data([1]), presentationTime: .init(milliseconds: 1)))
    try await publisher.appendVideo(videoSample(keyFrame: false, timestamp: 2))
    #expect(await publisher.state == .reconnecting(attempt: 0))
    try await publisher.appendVideo(videoSample(keyFrame: true, timestamp: 3))
    #expect(await publisher.state == .publishing)
    await publisher.finish()
  }

  @Test func mediaEncodingFailureDoesNotReconnect() async throws {
    let transport = MockRTMPTransport()
    let publisher = YouTubeRTMPSPublisher(transport: transport, reconnectDelays: [.zero])
    try await publisher.connect(
      to: destination("secret"), videoFormat: videoFormat, audioFormat: audioFormat)

    await #expect(throws: YouTubeRTMPSError.self) {
      try await publisher.appendVideo(
        YouTubeRTMPSVideoSample(
          avccData: Data([0, 0, 0, 1, 0x65]),
          presentationTime: .init(milliseconds: -1), decodeTime: .init(milliseconds: -1),
          isKeyFrame: true))
    }
    #expect(await publisher.state == .publishing)
    await publisher.finish()
  }

  @Test func connectionEstablishmentHasADeadline() async throws {
    let publisher = YouTubeRTMPSPublisher(
      transport: StalledRTMPTransport(), establishmentTimeout: .milliseconds(10))
    await #expect(throws: YouTubeRTMPSError.self) {
      try await publisher.connect(
        to: destination("secret"), videoFormat: videoFormat, audioFormat: audioFormat)
    }
    #expect(await publisher.state == .stopped)
  }

  @Test func finishCancelsASleepingReconnect() async throws {
    let transport = MockRTMPTransport()
    let publisher = YouTubeRTMPSPublisher(
      transport: transport, reconnectDelays: [.milliseconds(100)])
    try await publisher.connect(
      to: destination("secret"), videoFormat: videoFormat, audioFormat: audioFormat)
    await transport.failNextWriteAndPrepareReconnect()
    try await publisher.appendVideo(videoSample(keyFrame: false, timestamp: 1))

    let reconnect = Task {
      try await publisher.appendVideo(videoSample(keyFrame: true, timestamp: 2))
    }
    try await Task.sleep(for: .milliseconds(10))
    await publisher.finish()
    await #expect(throws: YouTubeRTMPSError.self) { try await reconnect.value }
    #expect(await publisher.state == .stopped)
    #expect(await transport.connectCount == 1)
  }

  @Test func commandErrorFailsConnectionImmediately() async throws {
    let transport = MockRTMPTransport(connectCommandName: "_error")
    let publisher = YouTubeRTMPSPublisher(
      transport: transport, establishmentTimeout: .seconds(1))
    await #expect(throws: YouTubeRTMPSError.self) {
      try await publisher.connect(
        to: destination("secret"), videoFormat: videoFormat, audioFormat: audioFormat)
    }
    #expect(await publisher.state == .stopped)
  }

  private var videoFormat: YouTubeRTMPSVideoFormat {
    YouTubeRTMPSVideoFormat(
      sequenceParameterSet: Data([0x67, 0x64, 0, 0x2A]),
      pictureParameterSet: Data([0x68, 0xEE]))
  }

  private var audioFormat: YouTubeRTMPSAudioFormat {
    YouTubeRTMPSAudioFormat(audioSpecificConfig: Data([0x11, 0x90]))
  }

  private func destination(_ key: String) -> YouTubeRTMPSDestination {
    try! YouTubeRTMPSDestination(
      ingestionURL: URL(string: "rtmps://a.rtmps.youtube.com/live2")!, streamName: key)
  }

  private func videoSample(keyFrame: Bool, timestamp: Int64) -> YouTubeRTMPSVideoSample {
    YouTubeRTMPSVideoSample(
      avccData: Data([0, 0, 0, 1, keyFrame ? 0x65 : 0x41]),
      presentationTime: .init(milliseconds: timestamp),
      decodeTime: .init(milliseconds: timestamp), isKeyFrame: keyFrame)
  }
}

private actor StalledRTMPTransport: RTMPTransport {
  private var receiveContinuation: CheckedContinuation<Data, any Error>?

  func connect(host _: String, port _: UInt16) async throws {}
  func send(_: Data) async throws {}
  func receive(minimum _: Int, maximum _: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { receiveContinuation = $0 }
  }
  func close() async {
    receiveContinuation?.resume(throwing: YouTubeRTMPSError.connectionFailed)
    receiveContinuation = nil
  }
}

private actor MockRTMPTransport: RTMPTransport {
  private(set) var writes: [Data] = []
  private(set) var connectCount = 0
  private var responses: [Data]
  private var reconnectResponses: [Data] = []
  private var failsNextWrite = false

  init(connectCommandName: String = "_result") {
    var handshake = Data([3])
    handshake.append(Data(repeating: 0, count: 3_072))
    responses = [
      handshake,
      Self.commandResponse(
        AMF0Encoder.encode([.string(connectCommandName), .number(1), .null])),
      Self.commandResponse(AMF0Encoder.encode([.string("_result"), .number(2), .null])),
      Self.createStreamResponse(),
      Self.commandResponse(
        AMF0Encoder.encode([.string("onStatus"), .number(0), .string("NetStream.Publish.Start")])),
    ]
  }

  func connect(host _: String, port _: UInt16) async throws {
    connectCount += 1
    if !reconnectResponses.isEmpty {
      responses = reconnectResponses
      reconnectResponses = []
    }
  }
  func send(_ data: Data) async throws {
    if failsNextWrite {
      failsNextWrite = false
      throw YouTubeRTMPSError.connectionFailed
    }
    writes.append(data)
  }
  func receive(minimum _: Int, maximum _: Int) async throws -> Data {
    guard !responses.isEmpty else {
      try await Task.sleep(for: .milliseconds(10))
      return Data([0])
    }
    return responses.removeFirst()
  }
  func close() async {}

  func failNextWriteAndPrepareReconnect() {
    failsNextWrite = true
    var handshake = Data([3])
    handshake.append(Data(repeating: 0, count: 3_072))
    reconnectResponses = [
      handshake,
      Self.commandResponse(AMF0Encoder.encode([.string("_result"), .number(1), .null])),
      Self.commandResponse(AMF0Encoder.encode([.string("_result"), .number(2), .null])),
      Self.createStreamResponse(),
      Self.commandResponse(
        AMF0Encoder.encode([.string("onStatus"), .number(0), .string("NetStream.Publish.Start")])),
    ]
  }

  private static func createStreamResponse() -> Data {
    commandResponse(AMF0Encoder.encode([.string("_result"), .number(4), .null, .number(7)]))
  }

  private static func commandResponse(_ payload: Data) -> Data {
    try! RTMPChunkEncoder().encode(
      chunkStreamID: 3, messageTypeID: 20, messageStreamID: 0, timestamp: 0,
      payload: payload)
  }
}
