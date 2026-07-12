// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXMP4
import XCTest

@testable import LDTXProgramRuntime

final class AudioSideStreamSegmentPipelineTests: XCTestCase {
    func testWritesInitializationBeforeMediaAndDrainsBeforeFinishReturns() async throws {
        let directory = URL(
            fileURLWithPath: "/private/tmp/LDTXAudioSideStreamPipelineTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = try HLSByteRangeTrackRecorder(
            directory: directory,
            mediaFileName: "side-track.mp4",
            playlistFileName: "side-track.m3u8",
            targetDurationSeconds: 2
        )
        let pipeline = AudioSideStreamSegmentPipeline()
        pipeline.start { segment in
            try recorder.write(segment)
        }

        pipeline.yield(SegmentedMP4Segment(
            kind: .initialization,
            data: Data("initialization".utf8)
        ))
        pipeline.yield(SegmentedMP4Segment(
            kind: .media(number: 1),
            data: Data("media".utf8),
            durationSeconds: 1
        ))
        await withCheckedContinuation { continuation in
            pipeline.drain { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            pipeline.finish { continuation.resume() }
        }
        recorder.finish()

        let media = try Data(contentsOf: directory.appendingPathComponent("side-track.mp4"))
        XCTAssertEqual(media, Data("initializationmedia".utf8))

        let playlist = try String(
            contentsOf: directory.appendingPathComponent("side-track.m3u8"),
            encoding: .utf8
        )
        let mapRange = try XCTUnwrap(playlist.range(of: "#EXT-X-MAP"))
        let mediaRange = try XCTUnwrap(playlist.range(of: "#EXTINF"))
        XCTAssertLessThan(mapRange.lowerBound, mediaRange.lowerBound)
        XCTAssertTrue(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    func testPerformIsSerializedWithSegmentWrites() async throws {
        let eventLog = AudioSideStreamPipelineEventLog()
        let pipeline = AudioSideStreamSegmentPipeline()
        pipeline.start { segment in
            guard case let .media(number) = segment.kind else { return }
            eventLog.append("segment-\(number)")
        }

        pipeline.yield(SegmentedMP4Segment(
            kind: .media(number: 1),
            data: Data(),
            durationSeconds: 1
        ))
        try pipeline.perform {
            eventLog.append("rotate")
        }
        pipeline.yield(SegmentedMP4Segment(
            kind: .media(number: 2),
            data: Data(),
            durationSeconds: 1
        ))
        await withCheckedContinuation { continuation in
            pipeline.finish { continuation.resume() }
        }

        let events = eventLog.snapshot()
        XCTAssertEqual(events, ["segment-1", "rotate", "segment-2"])
    }
}

private final class AudioSideStreamPipelineEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}
