// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import Testing

struct DASHManifestTests {
  @Test func generatesDynamicMPDWithEmbeddedInitialization() throws {
    let date = Date(timeIntervalSince1970: 1_704_067_200)
    let configuration = DASHManifestConfiguration(
      availabilityStartTime: date,
      minimumUpdatePeriodSeconds: 5,
      segmentTimeline: [
        DASHSegmentTimelineEntry(number: 1, startTimeSeconds: 0.2, durationSeconds: 0.2),
        DASHSegmentTimelineEntry(number: 2, startTimeSeconds: 0.4, durationSeconds: 1),
        DASHSegmentTimelineEntry(number: 3, startTimeSeconds: 1.4, durationSeconds: 2.04),
        DASHSegmentTimelineEntry(number: 4, startTimeSeconds: 3.44, durationSeconds: 4.2),
      ],
      initialization: .embedded(data: Data([0x00, 0x01, 0x02]))
    )

    let xml = try DASHManifestGenerator.xml(configuration: configuration)

    #expect(xml.contains(#"type="dynamic""#))
    #expect(xml.contains(#"minimumUpdatePeriod="PT5S""#))
    #expect(!xml.contains(#" duration=""#))
    #expect(xml.contains(#"<S t="200" d="200"/>"#))
    #expect(xml.contains(#"<S t="1400" d="2040"/>"#))
    #expect(xml.contains(#"media="media$Number%09d$.mp4""#))
    #expect(xml.contains(#"initialization="data:video/mp4;base64,AAEC""#))
    #expect(xml.contains(#"ContentComponent id="1" contentType="video""#))
    #expect(xml.contains(#"ContentComponent id="2" contentType="audio""#))
    #expect(xml.contains(#"codecs="avc1.64002a,mp4a.40.2""#))
    #expect(xml.contains(#"audioSamplingRate="48000""#))
  }

  @Test func rejectsYouTubeInvalidUpdatePeriod() {
    let configuration = DASHManifestConfiguration(
      minimumUpdatePeriodSeconds: 61,
      initialization: .embedded(data: Data())
    )

    #expect(throws: DASHManifestError.invalidMinimumUpdatePeriod(61)) {
      try DASHManifestGenerator.xml(configuration: configuration)
    }
  }

  @Test func embeddedInitializationUsesStandardBase64() throws {
    let configuration = DASHManifestConfiguration(
      segmentTimeline: [
        DASHSegmentTimelineEntry(number: 1, startTimeSeconds: 0, durationSeconds: 1)
      ],
      initialization: .embedded(data: Data([0xfb, 0xff, 0xff]))
    )

    let xml = try DASHManifestGenerator.xml(configuration: configuration)

    #expect(xml.contains(#"initialization="data:video/mp4;base64,+///""#))
  }

  @Test func generatesStaticMPDWithFileInitialization() throws {
    let configuration = DASHManifestConfiguration(
      kind: .static,
      mediaPresentationDurationSeconds: 6,
      segmentTimeline: [
        DASHSegmentTimelineEntry(number: 1, startTimeSeconds: 0, durationSeconds: 2),
        DASHSegmentTimelineEntry(number: 2, startTimeSeconds: 2, durationSeconds: 4),
      ],
      initialization: .url("init.mp4")
    )

    let xml = try DASHManifestGenerator.xml(configuration: configuration)

    #expect(xml.contains(#"type="static""#))
    #expect(xml.contains(#"mediaPresentationDuration="PT6S""#))
    #expect(xml.contains(#"initialization="init.mp4""#))
    #expect(!xml.contains("availabilityStartTime"))
    #expect(!xml.contains("minimumUpdatePeriod"))
  }

  @Test func rejectsMissingReversedAndNoncontiguousTimeline() {
    let missing = DASHManifestConfiguration(
      initialization: .embedded(data: Data()))
    #expect(throws: DASHManifestError.invalidDuration) {
      try DASHManifestGenerator.xml(configuration: missing)
    }

    let reversed = DASHManifestConfiguration(
      segmentTimeline: [
        DASHSegmentTimelineEntry(number: 1, startTimeSeconds: 2, durationSeconds: 1),
        DASHSegmentTimelineEntry(number: 2, startTimeSeconds: 1, durationSeconds: 1),
      ],
      initialization: .embedded(data: Data()))
    #expect(throws: DASHManifestError.invalidDuration) {
      try DASHManifestGenerator.xml(configuration: reversed)
    }

    let skipped = DASHManifestConfiguration(
      segmentTimeline: [
        DASHSegmentTimelineEntry(number: 1, startTimeSeconds: 0, durationSeconds: 1),
        DASHSegmentTimelineEntry(number: 3, startTimeSeconds: 1, durationSeconds: 1),
      ],
      initialization: .embedded(data: Data()))
    #expect(throws: DASHManifestError.invalidDuration) {
      try DASHManifestGenerator.xml(configuration: skipped)
    }
  }
}
