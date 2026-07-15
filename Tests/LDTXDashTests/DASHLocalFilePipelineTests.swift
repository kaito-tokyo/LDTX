// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXMP4
import Testing

struct DASHLocalFilePipelineTests {
    @Test func writesManifestAndMediaSegmentsToDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDTXDashTests-DASH-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let pipeline = DASHLocalFilePipeline(
            directory: directory,
            manifestConfiguration: DASHManifestConfiguration(
                availabilityStartTime: Date(timeIntervalSince1970: 1_704_067_200),
                initialization: .embedded(data: Data()),
                representation: .default1080p60
            )
        )

        let manifestEvent = try pipeline.write(
            SegmentedMP4Segment(kind: .initialization, data: Data([0x00, 0x01, 0x02]))
        )
        let initialManifestByteCount = try Data(contentsOf: directory.appendingPathComponent("manifest.mpd")).count
        let mediaEvent = try pipeline.write(
            SegmentedMP4Segment(kind: .media(number: 1), data: Data([0x03, 0x04]))
        )

        let manifestURL = directory.appendingPathComponent("manifest.mpd")
        let initializationURL = directory.appendingPathComponent("init.mp4")
        let mediaURL = directory.appendingPathComponent("media000000001.mp4")
        #expect(
            manifestEvent == .manifestWritten(
                manifestURL,
                byteCount: initialManifestByteCount,
                initializationURL: initializationURL,
                initializationByteCount: 3
            )
        )
        #expect(mediaEvent == .mediaSegmentWritten(mediaURL, number: 1, byteCount: 2))
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(try Data(contentsOf: initializationURL) == Data([0x00, 0x01, 0x02]))
        #expect(try Data(contentsOf: mediaURL) == Data([0x03, 0x04]))
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        #expect(manifest.contains(#"type="static""#))
        #expect(manifest.contains(#"initialization="init.mp4""#))
        #expect(manifest.contains(#"mediaPresentationDuration="PT2S""#))
        #expect(!manifest.contains("AAEC"))
    }

    @Test func rejectsMediaBeforeInitialization() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDTXDashTests-DASH-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let pipeline = DASHLocalFilePipeline(
            directory: directory,
            manifestConfiguration: DASHManifestConfiguration(initialization: .embedded(data: Data()))
        )

        do {
            _ = try pipeline.write(
                SegmentedMP4Segment(kind: .media(number: 1), data: Data([0x03, 0x04]))
            )
            Issue.record("Expected media-before-initialization error")
        } catch let error as DASHLocalFilePipelineError {
            #expect(error == .mediaSegmentBeforeInitialization(1))
        }
    }
}
