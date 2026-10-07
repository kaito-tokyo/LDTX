// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXRecordBundleFormat
import Testing

@Suite struct RecordingDASHManifestIntegrationTestSuite {
  @Test func periodOffsetAndMissingRepresentation() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try """
    <MPD><Period start="PT1.5S"><AdaptationSet><Representation>
    <SegmentList timescale="1000" presentationTimeOffset="2000">
    <Initialization sourceURL="video%20track.mp4"/>
    <SegmentTimeline><S t="2250" d="1000"/></SegmentTimeline>
    </SegmentList></Representation></AdaptationSet></Period></MPD>
    """.write(to: url, atomically: true, encoding: .utf8)
    let timeline = try RecordingDASHManifestTimeline(contentsOf: url)
    #expect(timeline.presentationStart(for: "video track.mp4") == 1_750_000_000)
    #expect(timeline.presentationStart(for: "missing.mp4") == nil)
    #expect(timeline.audioPresentationStart(for: "video track.mp4") == nil)
  }

  @Test func rejectsMalformedXML() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try "<MPD><Period>".write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: RecordingDASHManifestError.self) {
      try RecordingDASHManifestTimeline(contentsOf: url)
    }
  }
}
