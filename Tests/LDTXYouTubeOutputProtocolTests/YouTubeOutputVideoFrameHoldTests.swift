// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXYouTubeOutputProtocol

struct YouTubeOutputVideoFrameHoldTests {
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
