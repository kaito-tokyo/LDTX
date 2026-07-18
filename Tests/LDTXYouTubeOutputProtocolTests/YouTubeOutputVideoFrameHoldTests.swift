// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import Testing

@testable import LDTXYouTubeOutputProtocol

struct YouTubeOutputVideoFrameHoldTests {
  @Test func sharedTimelinePreservesAudioVideoOffsetAcrossTimescales() throws {
    var timeline = YouTubeOutputMediaTimeline(
      outputOffset: YouTubeOutputMediaTime(value: 1, timescale: 1))
    let origin = YouTubeOutputMediaTime(value: 60_000, timescale: 600)
    let videoTime = YouTubeOutputMediaTime(value: 60_000, timescale: 600)
    let audioTime = YouTubeOutputMediaTime(value: 4_806_000, timescale: 48_000)

    let established = timeline.establishOrigin(at: origin)
    let establishedAgain = timeline.establishOrigin(at: YouTubeOutputMediaTime(value: 0, timescale: 1))
    #expect(established)
    #expect(!establishedAgain)
    let translatedVideo = try #require(timeline.translate(videoTime))
    let translatedAudio = try #require(timeline.translate(audioTime))

    #expect(translatedVideo == YouTubeOutputMediaTime(value: 600, timescale: 600))
    #expect(translatedAudio == YouTubeOutputMediaTime(value: 54_000, timescale: 48_000))
    let inputOffset = CMTimeSubtract(audioTime.cmTime, videoTime.cmTime)
    let outputOffset = CMTimeSubtract(translatedAudio.cmTime, translatedVideo.cmTime)
    #expect(CMTimeCompare(inputOffset, outputOffset) == 0)
  }

  @Test func sharedTimelineRejectsPresentationTimesBeforeItsOrigin() {
    var timeline = YouTubeOutputMediaTimeline()

    #expect(!timeline.startsAtOrAfterOrigin(YouTubeOutputMediaTime(value: 100, timescale: 1)))
    let established = timeline.establishOrigin(at: YouTubeOutputMediaTime(value: 100, timescale: 1))
    #expect(established)
    #expect(!timeline.startsAtOrAfterOrigin(YouTubeOutputMediaTime(value: 99, timescale: 1)))
    #expect(timeline.startsAtOrAfterOrigin(YouTubeOutputMediaTime(value: 100, timescale: 1)))
    #expect(timeline.startsAtOrAfterOrigin(YouTubeOutputMediaTime(value: 101, timescale: 1)))
  }

  @Test func sharedTimelineUsesTheSameTranslationForDecodeTime() throws {
    var timeline = YouTubeOutputMediaTimeline(
      outputOffset: YouTubeOutputMediaTime(value: 1, timescale: 1))
    let established = timeline.establishOrigin(
      at: YouTubeOutputMediaTime(value: 3_000, timescale: 30))
    #expect(established)

    let decodeTime = try #require(
      timeline.translate(YouTubeOutputMediaTime(value: 2_999, timescale: 30)))
    #expect(decodeTime == YouTubeOutputMediaTime(value: 29, timescale: 30))
  }

  @Test func extendsPreviousFrameUntilNextPresentationTime() throws {
    var hold = YouTubeOutputVideoFrameHold()

    #expect(hold.append(frame(at: 0)) == nil)
    let firstValue = hold.append(frame(at: 1))
    let heldValue = hold.append(frame(at: 10))
    let finalValue = hold.finish()
    let first = try #require(firstValue)
    let held = try #require(heldValue)
    let final = try #require(finalValue)

    #expect(first.duration == YouTubeOutputMediaTime(value: 1, timescale: 30))
    #expect(held.presentationTime.value == 1)
    #expect(held.duration == YouTubeOutputMediaTime(value: 9, timescale: 30))
    #expect(final.presentationTime.value == 10)
    #expect(final.duration == YouTubeOutputMediaTime(value: 1, timescale: 30))
  }

  @Test func singleFrameUsesDefaultCadenceAtFinish() throws {
    var hold = YouTubeOutputVideoFrameHold()
    #expect(hold.append(frame(at: 42)) == nil)

    let finalValue = hold.finish(defaultFrameRate: 60)
    let final = try #require(finalValue)

    #expect(final.duration == YouTubeOutputMediaTime(value: 1, timescale: 60))
  }

  private func frame(at value: Int64) -> YouTubeOutputH264AccessUnit {
    YouTubeOutputH264AccessUnit(
      presentationTime: YouTubeOutputMediaTime(value: value, timescale: 30),
      decodeTime: nil,
      duration: YouTubeOutputMediaTime(value: 0, timescale: 1),
      isKeyFrame: value == 0,
      avccData: Data([0, 0, 0, 1])
    )
  }
}

private extension YouTubeOutputMediaTime {
  var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
}
