// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXYouTubeOutputProtocol
import XCTest

@testable import LDTXProgramRuntime

final class YouTubeOutputMediaBacklogTests: XCTestCase {
  func testBackpressureWaitsForKeyFrameAndAlignsAudioAtLiveEdge() throws {
    var backlog = YouTubeOutputMediaBacklog(maximumVideoCount: 2, maximumAudioCount: 2)
    let format = YouTubeOutputH264Format(
      parameterSets: [Data([1]), Data([2])], nalUnitHeaderLength: 4, width: 320, height: 180)

    for value in 1...3 {
      backlog.appendVideo(
        video(Int64(value), isKeyFrame: value == 1), format: value == 1 ? format : nil)
      backlog.appendAudio(audio(Int64(value)))
    }

    XCTAssertNil(backlog.takeBatch())

    backlog.appendAudio(audio(3))
    backlog.appendVideo(video(4, isKeyFrame: true), format: nil)
    backlog.appendAudio(audio(3))
    backlog.appendAudio(audio(4))
    backlog.appendVideo(video(5, isKeyFrame: false), format: nil)

    let batch = try XCTUnwrap(backlog.takeBatch())
    XCTAssertEqual(batch.video.map(\.presentationTime.value), [4, 5])
    XCTAssertEqual(batch.audio.map(\.presentationTime.value), [6_400])
    XCTAssertTrue(batch.video.first?.isKeyFrame == true)
    XCTAssertEqual(batch.videoFormat, format)
    XCTAssertTrue(backlog.isEmpty)
    XCTAssertNil(backlog.takeBatch())
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
