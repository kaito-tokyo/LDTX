// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXMP4
import LDTXYouTubeOutputProtocol
import Testing

@testable import LDTXProgramRuntime

struct DASHStreamContinuityTests {
  @Test func youTubeOutputFingerprintIsStableAcrossAudioTrackOrdering() {
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

    #expect(first.outputServiceValue == second.outputServiceValue)
    #expect(first.outputServiceValue.hasPrefix("v1:"))
  }

  @Test func continuityReusesMatchingEndpointAndOutputFingerprint() {
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

    #expect(state.canResume(endpoint: endpoint, outputConfigurationFingerprint: fingerprint))
    #expect(!state.canResume(
        endpoint: DASHIngestEndpoint(
          baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=other&file=")!
        ),
        outputConfigurationFingerprint: fingerprint))
  }

  @Test func continuityTracksLatestInitAndNextMediaSegmentNumber() {
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

    #expect(state.latestInitSegment == Data([0xAA]))
    #expect(state.nextMediaSegmentNumber == 8)
  }

  @Test func checkpointUpdatesContinuityWhenFingerprintMatches() {
    let fingerprint = makeFingerprint()
    var state = makeContinuityState(fingerprint: fingerprint)
    let availabilityStartTime = Date(timeIntervalSince1970: 1_900_000_000)

    let applied = state.apply(
      YouTubeOutputCheckpoint(
        nextMediaSegmentNumber: 91,
        initializationSegment: Data([0x91]),
        availabilityStartTime: availabilityStartTime,
        configurationFingerprint: fingerprint.outputServiceValue))

    #expect(applied)
    #expect(state.nextMediaSegmentNumber == 91)
    #expect(state.latestInitSegment == Data([0x91]))
    #expect(state.availabilityStartTime == availabilityStartTime)
  }

  @Test func checkpointDoesNotMutateContinuityWhenFingerprintDiffers() {
    let fingerprint = makeFingerprint()
    var state = makeContinuityState(fingerprint: fingerprint)
    let original = state

    let applied = state.apply(
      YouTubeOutputCheckpoint(
        nextMediaSegmentNumber: 91,
        initializationSegment: Data([0x91]),
        availabilityStartTime: Date(timeIntervalSince1970: 1_900_000_000),
        configurationFingerprint: "different"))

    #expect(!applied)
    #expect(state == original)
  }

  @MainActor
  @Test func continuityStoreKeepsEndpointsIndependent() throws {
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
    let store = YouTubeOutputWorkspaceStateStore()
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

    #expect(store.state(endpointIdentity: firstEndpointIdentity) == firstState)
    #expect(store.state(endpointIdentity: secondEndpointIdentity) == secondState)
    #expect(store.state(endpointIdentity: nil) == nil)
  }

  @MainActor
  @Test func workspaceStateStoreKeepsServiceProcessCheckpointOnlyInMemory() {
    let endpoint = "https://upload.youtube.com/dash_upload?cid=checkpoint&file="
    let fingerprint = makeFingerprint()
    let expected = DASHStreamContinuityState(
      endpointIdentity: endpoint,
      availabilityStartTime: Date(timeIntervalSince1970: 1_900_000_000),
      nextMediaSegmentNumber: 92,
      latestInitSegment: Data([0x92]),
      latestAudioInitSegments: [:],
      outputConfigurationFingerprint: fingerprint,
      nextMediaTimeSeconds: 184)

    let store = YouTubeOutputWorkspaceStateStore()
    store.setState(expected, endpointIdentity: endpoint)
    let separateWorkspaceStore = YouTubeOutputWorkspaceStateStore()

    #expect(store.state(endpointIdentity: endpoint) == expected)
    #expect(separateWorkspaceStore.state(endpointIdentity: endpoint) == nil)
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
