// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXYouTubeOutputProtocol
import XCTest

@testable import LDTXProgramRuntime

final class YouTubeOutputMediaBacklogTests: XCTestCase {
  func testAcceptedVideoAndAudioArePreservedInFIFOOrder() throws {
    var backlog = YouTubeOutputMediaBacklog(maximumVideoCount: 3, maximumAudioCount: 3)
    let format = YouTubeOutputH264Format(
      parameterSets: [Data([1]), Data([2])], nalUnitHeaderLength: 4, width: 320, height: 180)

    try backlog.appendVideo(video(1, isKeyFrame: true), format: format)
    try backlog.appendAudio(audio(1))
    try backlog.appendVideo(video(2, isKeyFrame: false), format: nil)
    try backlog.appendAudio(audio(2))

    let batch = try XCTUnwrap(backlog.takeBatch())
    XCTAssertEqual(batch.video.map(\.presentationTime.value), [1, 2])
    XCTAssertEqual(batch.audio.map(\.presentationTime.value), [1_600, 3_200])
    XCTAssertEqual(batch.videoFormat, format)
    XCTAssertTrue(backlog.isEmpty)
  }

  func testVideoOverflowFailsWithoutDiscardingAcceptedSamples() throws {
    var backlog = YouTubeOutputMediaBacklog(maximumVideoCount: 2, maximumAudioCount: 2)
    try backlog.appendVideo(video(1, isKeyFrame: true), format: nil)
    try backlog.appendVideo(video(2, isKeyFrame: false), format: nil)

    XCTAssertThrowsError(try backlog.appendVideo(video(3, isKeyFrame: false), format: nil)) {
      XCTAssertEqual($0 as? YouTubeOutputMediaBacklogError, .videoLimitExceeded)
    }
    XCTAssertEqual(backlog.video.map(\.presentationTime.value), [1, 2])
  }

  func testAudioOverflowFailsWithoutDiscardingAcceptedSamples() throws {
    var backlog = YouTubeOutputMediaBacklog(maximumVideoCount: 2, maximumAudioCount: 2)
    try backlog.appendAudio(audio(1))
    try backlog.appendAudio(audio(2))

    XCTAssertThrowsError(try backlog.appendAudio(audio(3))) {
      XCTAssertEqual($0 as? YouTubeOutputMediaBacklogError, .audioLimitExceeded)
    }
    XCTAssertEqual(backlog.audio.map(\.presentationTime.value), [1_600, 3_200])
  }

  private func video(_ value: Int64, isKeyFrame: Bool) -> YouTubeOutputH264AccessUnit {
    YouTubeOutputH264AccessUnit(
      presentationTime: .init(value: value, timescale: 30),
      decodeTime: nil,
      duration: .init(value: 1, timescale: 30),
      isKeyFrame: isKeyFrame,
      avccData: Data([0, 0, 0, 1, 0x09]))
  }

  private func audio(_ value: Int64) -> YouTubeOutputPCMBuffer {
    YouTubeOutputPCMBuffer(
      presentationTime: .init(value: value * 1_600, timescale: 48_000),
      duration: .init(value: 1, timescale: 48_000),
      sampleRate: 48_000,
      channelCount: 2,
      frameCount: 1,
      sampleFormat: .float32Interleaved,
      data: Data(count: 8))
  }
}
