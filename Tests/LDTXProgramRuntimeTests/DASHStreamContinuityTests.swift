// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXDash
import LDTXMP4
import LDTXYouTubeOutputProtocol
import XCTest

@testable import LDTXProgramRuntime

final class DASHStreamContinuityTests: XCTestCase {
  func testYouTubeOutputFingerprintIsStableAcrossAudioTrackOrdering() {
    let writerConfiguration = SegmentedMP4WriterConfiguration(
      width: 1_920,
      height: 1_080,
      frameRate: 60,
      videoBitRate: 6_000_000
    )
    let first = DASHStreamOutputConfigurationFingerprint(
      writerConfiguration: writerConfiguration,
      audioTrackIDs: ["sub", "main"]
    )
    let second = DASHStreamOutputConfigurationFingerprint(
      writerConfiguration: writerConfiguration,
      audioTrackIDs: ["main", "sub"]
    )

    XCTAssertEqual(first.outputServiceValue, second.outputServiceValue)
    XCTAssertTrue(first.outputServiceValue.hasPrefix("v1:"))
  }

  func testContinuityReusesMatchingEndpointAndOutputFingerprint() {
    let writerConfiguration = SegmentedMP4WriterConfiguration(
      width: 1_920,
      height: 1_080,
      frameRate: 60,
      videoBitRate: 6_000_000
    )
    let fingerprint = DASHStreamOutputConfigurationFingerprint(
      writerConfiguration: writerConfiguration,
      audioTrackIDs: ["main", "sub"]
    )
    let endpoint = DASHIngestEndpoint(
      baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!
    )
    let state = DASHStreamContinuityState(
      endpointIdentity: endpoint.baseURL.absoluteString,
      availabilityStartTime: Date(timeIntervalSince1970: 1_800_000_000),
      nextMediaSegmentNumber: 42,
      latestInitSegment: Data([0x00, 0x01]),
      latestAudioInitSegments: [:],
      outputConfigurationFingerprint: fingerprint
    )

    XCTAssertTrue(state.canResume(endpoint: endpoint, outputConfigurationFingerprint: fingerprint))
    XCTAssertFalse(
      state.canResume(
        endpoint: DASHIngestEndpoint(
          baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=other&file=")!
        ),
        outputConfigurationFingerprint: fingerprint
      )
    )
  }

  func testContinuityTracksLatestInitAndNextMediaSegmentNumber() {
    let writerConfiguration = SegmentedMP4WriterConfiguration(
      width: 1_280,
      height: 720,
      frameRate: 30,
      videoBitRate: 2_500_000
    )
    let fingerprint = DASHStreamOutputConfigurationFingerprint(
      writerConfiguration: writerConfiguration,
      audioTrackIDs: []
    )
    var state = DASHStreamContinuityState(
      endpointIdentity: nil,
      availabilityStartTime: .distantPast,
      nextMediaSegmentNumber: 1,
      latestInitSegment: nil,
      latestAudioInitSegments: [:],
      outputConfigurationFingerprint: fingerprint
    )

    state.noteMainSegment(SegmentedMP4Segment(kind: .initialization, data: Data([0xAA])))
    state.noteMainSegment(SegmentedMP4Segment(kind: .media(number: 7), data: Data([0xBB])))

    XCTAssertEqual(state.latestInitSegment, Data([0xAA]))
    XCTAssertEqual(state.nextMediaSegmentNumber, 8)
  }

  func testCheckpointUpdatesContinuityWhenFingerprintMatches() {
    let fingerprint = makeFingerprint()
    var state = makeContinuityState(fingerprint: fingerprint)
    let availabilityStartTime = Date(timeIntervalSince1970: 1_900_000_000)

    let applied = state.apply(
      YouTubeOutputCheckpoint(
        nextMediaSegmentNumber: 91,
        initializationSegment: Data([0x91]),
        availabilityStartTime: availabilityStartTime,
        configurationFingerprint: fingerprint.outputServiceValue))

    XCTAssertTrue(applied)
    XCTAssertEqual(state.nextMediaSegmentNumber, 91)
    XCTAssertEqual(state.latestInitSegment, Data([0x91]))
    XCTAssertEqual(state.availabilityStartTime, availabilityStartTime)
  }

  func testCheckpointDoesNotMutateContinuityWhenFingerprintDiffers() {
    let fingerprint = makeFingerprint()
    var state = makeContinuityState(fingerprint: fingerprint)
    let original = state

    let applied = state.apply(
      YouTubeOutputCheckpoint(
        nextMediaSegmentNumber: 91,
        initializationSegment: Data([0x91]),
        availabilityStartTime: Date(timeIntervalSince1970: 1_900_000_000),
        configurationFingerprint: "different"))

    XCTAssertFalse(applied)
    XCTAssertEqual(state, original)
  }

  @MainActor
  func testContinuityStoreKeepsEndpointsIndependent() throws {
    let fingerprint = DASHStreamOutputConfigurationFingerprint(
      writerConfiguration: SegmentedMP4WriterConfiguration(
        width: 1_280,
        height: 720,
        frameRate: 30,
        videoBitRate: 2_500_000
      ),
      audioTrackIDs: []
    )
    let firstEndpointIdentity = "https://upload.youtube.com/dash_upload?cid=first&file="
    let secondEndpointIdentity = "https://upload.youtube.com/dash_upload?cid=second&file="
    let store = ProgramDASHStreamContinuityStore()
    let firstState = DASHStreamContinuityState(
      endpointIdentity: firstEndpointIdentity,
      availabilityStartTime: .distantPast,
      nextMediaSegmentNumber: 41,
      latestInitSegment: Data([0x01]),
      latestAudioInitSegments: [:],
      outputConfigurationFingerprint: fingerprint
    )
    let secondState = DASHStreamContinuityState(
      endpointIdentity: secondEndpointIdentity,
      availabilityStartTime: .distantPast,
      nextMediaSegmentNumber: 73,
      latestInitSegment: Data([0x02]),
      latestAudioInitSegments: [:],
      outputConfigurationFingerprint: fingerprint
    )

    store.setState(firstState, endpointIdentity: firstEndpointIdentity)
    store.setState(secondState, endpointIdentity: secondEndpointIdentity)

    XCTAssertEqual(store.state(endpointIdentity: firstEndpointIdentity), firstState)
    XCTAssertEqual(store.state(endpointIdentity: secondEndpointIdentity), secondState)
    XCTAssertNil(store.state(endpointIdentity: nil))
  }

  func testRecordingSplitDirectoryNamingKeepsFirstPartStable() {
    let baseDirectory = URL(fileURLWithPath: "/tmp/recordings", isDirectory: true)

    XCTAssertEqual(
      RecordingSplitState.directoryURL(
        baseDirectory: baseDirectory,
        recordID: "LDTX20260709T120000",
        partIndex: 1
      ).lastPathComponent,
      "LDTX20260709T120000.ldtxrecord"
    )
    XCTAssertEqual(
      RecordingSplitState.directoryURL(
        baseDirectory: baseDirectory,
        recordID: "LDTX20260709T120000",
        partIndex: 2
      ).lastPathComponent,
      "LDTX20260709T120000-part0002.ldtxrecord"
    )
  }

  private func makeFingerprint() -> DASHStreamOutputConfigurationFingerprint {
    DASHStreamOutputConfigurationFingerprint(
      writerConfiguration: SegmentedMP4WriterConfiguration(
        width: 1_280,
        height: 720,
        frameRate: 30,
        videoBitRate: 2_500_000),
      audioTrackIDs: [])
  }

  private func makeContinuityState(
    fingerprint: DASHStreamOutputConfigurationFingerprint
  ) -> DASHStreamContinuityState {
    DASHStreamContinuityState(
      endpointIdentity: nil,
      availabilityStartTime: Date(timeIntervalSince1970: 1_800_000_000),
      nextMediaSegmentNumber: 7,
      latestInitSegment: Data([0x07]),
      latestAudioInitSegments: [:],
      outputConfigurationFingerprint: fingerprint)
  }
}
