// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import LDTXCapture
import LDTXDash
import LDTXMedia
import LDTXSupport
import LDTXYouTube
import XCTest

final class FileMP4WriterTests: XCTestCase {
    func testSegmentedWriterStartsWithVideoToolboxPassthrough() async throws {
        let configuration = SegmentedMP4WriterConfiguration(
            width: 320,
            height: 180,
            frameRate: 30,
            videoBitRate: 800_000,
            segmentDurationSeconds: 2
        )

        let recorder = SegmentRecorder()
        let writer = try SegmentedMP4Writer(configuration: configuration) { segment in
            recorder.append(segment)
        }

        try Self.appendSyntheticAudioVideo(
            to: writer,
            configuration: configuration,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            durationSeconds: 3
        )

        try await writer.finish()

        XCTAssertTrue(recorder.segments.contains { $0.kind == .initialization })
    }

    func testSegmentedWriterHandles1080p60VideoToolboxPassthrough() async throws {
        try LDTXTestConfiguration.skipUnlessHeavyMediaTestsEnabled("1080p60 VideoToolbox segmented writer passthrough")

        let configuration = SegmentedMP4WriterConfiguration(
            width: 1_920,
            height: 1_080,
            frameRate: 60,
            videoBitRate: 9_000_000,
            segmentDurationSeconds: 2
        )

        let recorder = SegmentRecorder()
        let writer = try SegmentedMP4Writer(configuration: configuration) { segment in
            recorder.append(segment)
        }

        try Self.appendSyntheticAudioVideo(
            to: writer,
            configuration: configuration,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            durationSeconds: 3
        )

        try await writer.finish()

        let segments = recorder.segments
        XCTAssertTrue(segments.contains { $0.kind == .initialization })
        XCTAssertTrue(segments.contains {
            if case .media = $0.kind { true } else { false }
        })
        XCTAssertGreaterThanOrEqual(segments.mediaSegmentCount, 1)

        let outputDirectory = URL(
            fileURLWithPath: "/private/tmp/LDTXCoreTests-PendingVideoFlush-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Self.writeSegments(segments, to: outputDirectory)

        let playbackURL = try Self.writeConcatenatedPlaybackFile(in: outputDirectory)
        let playbackAsset = AVURLAsset(url: playbackURL)
        let videoTracks = try await playbackAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await playbackAsset.loadTracks(withMediaType: .audio)
        let playbackDuration = try await playbackAsset.load(.duration)

        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertGreaterThan(playbackDuration.seconds, 2.5)
        XCTAssertLessThan(playbackDuration.seconds, 3.5)
    }

    func testGenerateInspectableLocalDASHStream() async throws {
        try LDTXTestConfiguration.skipUnlessHeavyMediaTestsEnabled("inspectable local DASH stream generation")

        let outputDirectory = URL(
            fileURLWithPath: "/private/tmp/LDTXCoreTests-InspectableDASH",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: outputDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let configuration = SegmentedMP4WriterConfiguration(
            width: 640,
            height: 360,
            frameRate: 30,
            videoBitRate: 2_500_000,
            segmentDurationSeconds: 2
        )
        let recorder = SegmentRecorder()
        let writer = try SegmentedMP4Writer(configuration: configuration) { segment in
            recorder.append(segment)
        }

        var firstVideoSampleBuffer: CMSampleBuffer?
        let inputDurationSeconds = 10
        let framesPerAudioBuffer = 1_024
        let audioSampleCount = inputDurationSeconds * configuration.audioSampleRate
        var nextAudioSampleIndex = 0
        for frameIndex in 0..<(configuration.frameRate * inputDurationSeconds) {
            let videoSampleBuffer = try Self.makeVideoSampleBuffer(
                width: configuration.width,
                height: configuration.height,
                frameIndex: frameIndex,
                frameRate: configuration.frameRate,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            if firstVideoSampleBuffer == nil {
                firstVideoSampleBuffer = videoSampleBuffer
            }
            writer.append(sampleBuffer: videoSampleBuffer, kind: .video)

            let videoEndTime = CMTime(
                value: CMTimeValue(frameIndex + 1),
                timescale: CMTimeScale(configuration.frameRate)
            )
            while nextAudioSampleIndex < audioSampleCount,
                  CMTime(value: CMTimeValue(nextAudioSampleIndex), timescale: CMTimeScale(configuration.audioSampleRate)) < videoEndTime {
                let sampleCount = min(framesPerAudioBuffer, audioSampleCount - nextAudioSampleIndex)
                let audioSampleBuffer = try Self.makeAudioSampleBuffer(
                    sampleRate: configuration.audioSampleRate,
                    channelCount: configuration.audioChannelCount,
                    startSampleIndex: nextAudioSampleIndex,
                    sampleCount: sampleCount
                )
                writer.append(sampleBuffer: audioSampleBuffer, kind: .audio)
                nextAudioSampleIndex += sampleCount
            }
        }

        try await writer.finish()

        let segments = recorder.segments
        XCTAssertTrue(segments.contains { $0.kind == .initialization })
        XCTAssertGreaterThanOrEqual(segments.mediaSegmentCount, 4)

        let pipeline = DASHLocalFilePipeline(
            directory: outputDirectory,
            manifestConfiguration: DASHManifestConfiguration(
                availabilityStartTime: Date(timeIntervalSince1970: 1_800_000_000),
                timescale: 1_000,
                segmentDurationSeconds: configuration.segmentDurationSeconds,
                startNumber: configuration.startNumber,
                initialization: .url("init.mp4"),
                representation: DASHRepresentation(
                    id: "inspectable-360p30",
                    bandwidth: configuration.videoBitRate + configuration.audioBitRate,
                    width: configuration.width,
                    height: configuration.height,
                    frameRate: "\(configuration.frameRate)",
                    codecs: "avc1.64002a,mp4a.40.2"
                )
            )
        )

        for segment in segments {
            _ = try await pipeline.write(segment)
        }

        let manifestURL = outputDirectory.appendingPathComponent("manifest.mpd")
        let initializationURL = outputDirectory.appendingPathComponent("init.mp4")
        let firstMediaURL = outputDirectory.appendingPathComponent("media000000001.mp4")
        let mediaURLs = try Self.mediaSegmentURLs(in: outputDirectory)
        let playbackURL = try Self.writeConcatenatedPlaybackFile(in: outputDirectory)
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let playbackAsset = AVURLAsset(url: playbackURL)
        let playbackVideoTracks = try await playbackAsset.loadTracks(withMediaType: .video)
        let playbackAudioTracks = try await playbackAsset.loadTracks(withMediaType: .audio)
        let playbackDuration = try await playbackAsset.load(.duration)

        XCTAssertTrue(FileManager.default.fileExists(atPath: initializationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstMediaURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: playbackURL.path))
        XCTAssertGreaterThan(try Self.fileSize(at: initializationURL), 0)
        XCTAssertGreaterThan(try Self.fileSize(at: playbackURL), 100_000)
        XCTAssertGreaterThanOrEqual(mediaURLs.count, 4)
        for (mediaIndex, mediaURL) in mediaURLs.enumerated() {
            let mediaSize = try Self.fileSize(at: mediaURL)
            XCTAssertGreaterThan(mediaSize, 0, mediaURL.lastPathComponent)
            if mediaIndex < 4 {
                XCTAssertGreaterThan(mediaSize, 10_000, mediaURL.lastPathComponent)
            }
        }
        XCTAssertEqual(playbackVideoTracks.count, 1)
        XCTAssertEqual(playbackAudioTracks.count, 1)
        XCTAssertGreaterThan(playbackDuration.seconds, 7.5)
        XCTAssertLessThan(playbackDuration.seconds, 10.5)
        let playbackVideoSize = try await playbackVideoTracks[0].load(.naturalSize)
        XCTAssertEqual(Int(playbackVideoSize.width), configuration.width)
        XCTAssertEqual(Int(playbackVideoSize.height), configuration.height)
        XCTAssertTrue(manifest.contains(#"type="static""#))
        XCTAssertTrue(manifest.contains(#"profiles="urn:mpeg:dash:profile:isoff-live:2011""#))
        XCTAssertTrue(manifest.contains("<SegmentTemplate"))
        XCTAssertTrue(manifest.contains(#"initialization="init.mp4""#))
        XCTAssertTrue(manifest.contains(#"media="media$Number%09d$.mp4""#))
        XCTAssertTrue(manifest.contains("mediaPresentationDuration="))
        XCTAssertTrue(manifest.contains(#"ContentComponent id="1" contentType="video""#))
        XCTAssertTrue(manifest.contains(#"ContentComponent id="2" contentType="audio""#))
        XCTAssertTrue(manifest.contains(#"codecs="avc1.64002a,mp4a.40.2""#))
        XCTAssertTrue(manifest.contains(#"audioSamplingRate="48000""#))

        if let firstVideoSampleBuffer {
            print("Input video format: \(Self.videoFormatDescription(for: firstVideoSampleBuffer))")
        }
        print("Input writer configuration: \(Self.writerConfigurationDescription(configuration))")
        print("Inspectable DASH output: \(outputDirectory.path)")
        print("Inspectable DASH MPD: \(manifestURL.path)")
        print("Inspectable concatenated MP4: \(playbackURL.path)")
    }

    func testSegmentedWriterAllowsAudioToStartAfterFirstVideoPTS() async throws {
        try LDTXTestConfiguration.skipUnlessHeavyMediaTestsEnabled("segmented writer delayed-audio start")

        let configuration = SegmentedMP4WriterConfiguration(
            width: 640,
            height: 360,
            frameRate: 60,
            videoBitRate: 2_500_000,
            segmentDurationSeconds: 2
        )
        let recorder = SegmentRecorder()
        let writer = try SegmentedMP4Writer(configuration: configuration) { segment in
            recorder.append(segment)
        }

        let preRollAudioSampleBuffer = try Self.makeAudioSampleBuffer(
            sampleRate: configuration.audioSampleRate,
            channelCount: configuration.audioChannelCount,
            startSampleIndex: 0,
            sampleCount: 512
        )
        writer.append(sampleBuffer: preRollAudioSampleBuffer, kind: .audio)

        let durationSeconds = 3
        let frameCount = durationSeconds * configuration.frameRate
        let firstVideoFrameIndex = configuration.frameRate
        let firstAudioSampleIndex = configuration.audioSampleRate + 2_048
        let audioSampleCount = durationSeconds * configuration.audioSampleRate
        let framesPerAudioBuffer = 512
        var nextAudioSampleIndex = firstAudioSampleIndex

        for frameIndex in 0..<frameCount {
            let sourceFrameIndex = firstVideoFrameIndex + frameIndex
            let videoSampleBuffer = try Self.makeVideoSampleBuffer(
                width: configuration.width,
                height: configuration.height,
                frameIndex: sourceFrameIndex,
                frameRate: configuration.frameRate
            )
            writer.append(sampleBuffer: videoSampleBuffer, kind: .video)

            let videoEndTime = CMTime(
                value: CMTimeValue(sourceFrameIndex + 1),
                timescale: CMTimeScale(configuration.frameRate)
            )
            while nextAudioSampleIndex < firstAudioSampleIndex + audioSampleCount,
                  CMTime(value: CMTimeValue(nextAudioSampleIndex), timescale: CMTimeScale(configuration.audioSampleRate)) < videoEndTime {
                let sampleCount = min(
                    framesPerAudioBuffer,
                    firstAudioSampleIndex + audioSampleCount - nextAudioSampleIndex
                )
                let audioSampleBuffer = try Self.makeAudioSampleBuffer(
                    sampleRate: configuration.audioSampleRate,
                    channelCount: configuration.audioChannelCount,
                    startSampleIndex: nextAudioSampleIndex,
                    sampleCount: sampleCount
                )
                writer.append(sampleBuffer: audioSampleBuffer, kind: .audio)
                nextAudioSampleIndex += sampleCount
            }
        }

        try await writer.finish()

        XCTAssertTrue(recorder.segments.contains { $0.kind == .initialization })
        XCTAssertTrue(recorder.segments.contains {
            if case .media = $0.kind { true } else { false }
        })
    }

    func testSegmentedWriterStartsWhenFirstAudioAtVideoPTSArrivesBeforeVideo() async throws {
        try LDTXTestConfiguration.skipUnlessHeavyMediaTestsEnabled("segmented writer audio-first start")

        let configuration = SegmentedMP4WriterConfiguration(
            width: 640,
            height: 360,
            frameRate: 60,
            videoBitRate: 2_500_000,
            segmentDurationSeconds: 2
        )
        let recorder = SegmentRecorder()
        let writer = try SegmentedMP4Writer(configuration: configuration) { segment in
            recorder.append(segment)
        }

        let durationSeconds = 3
        let frameCount = durationSeconds * configuration.frameRate
        let audioSampleCount = durationSeconds * configuration.audioSampleRate
        let framesPerAudioBuffer = 512
        var nextAudioSampleIndex = 0

        let firstAudioSampleBuffer = try Self.makeFloat32AudioSampleBuffer(
            sampleRate: configuration.audioSampleRate,
            channelCount: configuration.audioChannelCount,
            startSampleIndex: 0,
            sampleCount: framesPerAudioBuffer
        )
        writer.append(sampleBuffer: firstAudioSampleBuffer, kind: .audio)
        nextAudioSampleIndex += framesPerAudioBuffer

        for frameIndex in 0..<frameCount {
            let videoSampleBuffer = try Self.makeVideoSampleBuffer(
                width: configuration.width,
                height: configuration.height,
                frameIndex: frameIndex,
                frameRate: configuration.frameRate
            )
            writer.append(sampleBuffer: videoSampleBuffer, kind: .video)

            let videoEndTime = CMTime(
                value: CMTimeValue(frameIndex + 1),
                timescale: CMTimeScale(configuration.frameRate)
            )
            while nextAudioSampleIndex < audioSampleCount,
                  CMTime(value: CMTimeValue(nextAudioSampleIndex), timescale: CMTimeScale(configuration.audioSampleRate)) < videoEndTime {
                let sampleCount = min(framesPerAudioBuffer, audioSampleCount - nextAudioSampleIndex)
                let audioSampleBuffer = try Self.makeFloat32AudioSampleBuffer(
                    sampleRate: configuration.audioSampleRate,
                    channelCount: configuration.audioChannelCount,
                    startSampleIndex: nextAudioSampleIndex,
                    sampleCount: sampleCount
                )
                writer.append(sampleBuffer: audioSampleBuffer, kind: .audio)
                nextAudioSampleIndex += sampleCount
            }
        }

        try await writer.finish()

        XCTAssertTrue(recorder.segments.contains { $0.kind == .initialization })
        XCTAssertTrue(recorder.segments.contains {
            if case .media = $0.kind { true } else { false }
        })
    }

    func testSegmentedWriterFlushesPendingVideoWhenAudioStartsWriter() async throws {
        try LDTXTestConfiguration.skipUnlessHeavyMediaTestsEnabled("segmented writer pending-video flush")

        let configuration = SegmentedMP4WriterConfiguration(
            width: 640,
            height: 360,
            frameRate: 60,
            videoBitRate: 2_500_000,
            segmentDurationSeconds: 2
        )
        let recorder = SegmentRecorder()
        let writer = try SegmentedMP4Writer(configuration: configuration) { segment in
            recorder.append(segment)
        }

        let durationSeconds = 3
        let frameCount = durationSeconds * configuration.frameRate
        for frameIndex in 0..<frameCount {
            let videoSampleBuffer = try Self.makeVideoSampleBuffer(
                width: configuration.width,
                height: configuration.height,
                frameIndex: frameIndex,
                frameRate: configuration.frameRate
            )
            writer.append(sampleBuffer: videoSampleBuffer, kind: .video)
        }

        let audioSampleCount = durationSeconds * configuration.audioSampleRate
        let framesPerAudioBuffer = 1_024
        var nextAudioSampleIndex = 0
        while nextAudioSampleIndex < audioSampleCount {
            let sampleCount = min(framesPerAudioBuffer, audioSampleCount - nextAudioSampleIndex)
            let audioSampleBuffer = try Self.makeFloat32AudioSampleBuffer(
                sampleRate: configuration.audioSampleRate,
                channelCount: configuration.audioChannelCount,
                startSampleIndex: nextAudioSampleIndex,
                sampleCount: sampleCount
            )
            writer.append(sampleBuffer: audioSampleBuffer, kind: .audio)
            nextAudioSampleIndex += sampleCount
        }

        try await writer.finish()

        XCTAssertTrue(recorder.segments.contains { $0.kind == .initialization })
        XCTAssertTrue(recorder.segments.contains {
            if case .media = $0.kind { true } else { false }
        })
    }

    func testSegmentedWriterAcceptsFloat32ProgramAudio() async throws {
        try LDTXTestConfiguration.skipUnlessHeavyMediaTestsEnabled("segmented writer Float32 program audio")

        let configuration = SegmentedMP4WriterConfiguration(
            width: 640,
            height: 360,
            frameRate: 60,
            videoBitRate: 2_500_000,
            segmentDurationSeconds: 2
        )
        let recorder = SegmentRecorder()
        let writer = try SegmentedMP4Writer(configuration: configuration) { segment in
            recorder.append(segment)
        }

        let durationSeconds = 3
        let frameCount = durationSeconds * configuration.frameRate
        let audioSampleCount = durationSeconds * configuration.audioSampleRate
        let framesPerAudioBuffer = 1_024
        var nextAudioSampleIndex = 0

        for frameIndex in 0..<frameCount {
            let videoSampleBuffer = try Self.makeVideoSampleBuffer(
                width: configuration.width,
                height: configuration.height,
                frameIndex: frameIndex,
                frameRate: configuration.frameRate
            )
            writer.append(sampleBuffer: videoSampleBuffer, kind: .video)

            let videoEndTime = CMTime(
                value: CMTimeValue(frameIndex + 1),
                timescale: CMTimeScale(configuration.frameRate)
            )
            while nextAudioSampleIndex < audioSampleCount,
                  CMTime(value: CMTimeValue(nextAudioSampleIndex), timescale: CMTimeScale(configuration.audioSampleRate)) < videoEndTime {
                let sampleCount = min(framesPerAudioBuffer, audioSampleCount - nextAudioSampleIndex)
                let audioSampleBuffer = try Self.makeFloat32AudioSampleBuffer(
                    sampleRate: configuration.audioSampleRate,
                    channelCount: configuration.audioChannelCount,
                    startSampleIndex: nextAudioSampleIndex,
                    sampleCount: sampleCount
                )
                writer.append(sampleBuffer: audioSampleBuffer, kind: .audio)
                nextAudioSampleIndex += sampleCount
            }
        }

        try await writer.finish()

        XCTAssertTrue(recorder.segments.contains { $0.kind == .initialization })
        XCTAssertTrue(recorder.segments.contains {
            if case .media = $0.kind { true } else { false }
        })
    }

    func testSegmentedWriterDropsRepeatedVideoPTS() async throws {
        try LDTXTestConfiguration.skipUnlessHeavyMediaTestsEnabled("segmented writer repeated video PTS drop")

        let configuration = SegmentedMP4WriterConfiguration(
            width: 640,
            height: 360,
            frameRate: 60,
            videoBitRate: 2_500_000,
            segmentDurationSeconds: 2
        )
        let recorder = SegmentRecorder()
        let writer = try SegmentedMP4Writer(configuration: configuration) { segment in
            recorder.append(segment)
        }

        let durationSeconds = 3
        let frameCount = durationSeconds * configuration.frameRate
        let audioSampleCount = durationSeconds * configuration.audioSampleRate
        let framesPerAudioBuffer = 1_024
        var nextAudioSampleIndex = 0

        for frameIndex in 0..<frameCount {
            let repeatedPresentationTime = CMTime(
                value: CMTimeValue(frameIndex / 2),
                timescale: 30
            )
            let videoSampleBuffer = try Self.makeVideoSampleBuffer(
                width: configuration.width,
                height: configuration.height,
                frameIndex: frameIndex,
                frameRate: configuration.frameRate,
                sourcePresentationTime: repeatedPresentationTime
            )
            writer.append(sampleBuffer: videoSampleBuffer, kind: .video)

            let videoEndTime = CMTime(
                value: CMTimeValue(frameIndex + 1),
                timescale: CMTimeScale(configuration.frameRate)
            )
            while nextAudioSampleIndex < audioSampleCount,
                  CMTime(value: CMTimeValue(nextAudioSampleIndex), timescale: CMTimeScale(configuration.audioSampleRate)) < videoEndTime {
                let sampleCount = min(framesPerAudioBuffer, audioSampleCount - nextAudioSampleIndex)
                let audioSampleBuffer = try Self.makeFloat32AudioSampleBuffer(
                    sampleRate: configuration.audioSampleRate,
                    channelCount: configuration.audioChannelCount,
                    startSampleIndex: nextAudioSampleIndex,
                    sampleCount: sampleCount
                )
                writer.append(sampleBuffer: audioSampleBuffer, kind: .audio)
                nextAudioSampleIndex += sampleCount
            }
        }

        try await writer.finish()

        XCTAssertTrue(recorder.segments.contains { $0.kind == .initialization })
        XCTAssertTrue(recorder.segments.contains {
            if case .media = $0.kind { true } else { false }
        })
    }

    func testSegmentedWriterAcceptsLargePTSFloat32ProgramAudio() async throws {
        try LDTXTestConfiguration.skipUnlessHeavyMediaTestsEnabled("segmented writer large-PTS Float32 program audio")

        let configuration = SegmentedMP4WriterConfiguration(
            width: 640,
            height: 360,
            frameRate: 60,
            videoBitRate: 2_500_000,
            segmentDurationSeconds: 2
        )
        let recorder = SegmentRecorder()
        let writer = try SegmentedMP4Writer(configuration: configuration) { segment in
            recorder.append(segment)
        }

        let durationSeconds = 3
        let frameCount = durationSeconds * configuration.frameRate
        let audioSampleCount = durationSeconds * configuration.audioSampleRate
        let framesPerAudioBuffer = 1_024
        let firstVideoPTS = CMTime(seconds: 52_655.0, preferredTimescale: 30_000)
        let firstAudioSampleIndex = 52_655 * configuration.audioSampleRate
        var nextAudioSampleIndex = firstAudioSampleIndex

        for frameIndex in 0..<frameCount {
            let videoPresentationTime = firstVideoPTS + CMTime(
                value: CMTimeValue(frameIndex),
                timescale: CMTimeScale(configuration.frameRate)
            )
            let videoSampleBuffer = try Self.makeVideoSampleBuffer(
                width: configuration.width,
                height: configuration.height,
                frameIndex: frameIndex,
                frameRate: configuration.frameRate,
                sourcePresentationTime: videoPresentationTime
            )
            writer.append(sampleBuffer: videoSampleBuffer, kind: .video)

            let videoEndTime = videoPresentationTime + CMTime(
                value: 1,
                timescale: CMTimeScale(configuration.frameRate)
            )
            while nextAudioSampleIndex < firstAudioSampleIndex + audioSampleCount,
                  CMTime(value: CMTimeValue(nextAudioSampleIndex), timescale: CMTimeScale(configuration.audioSampleRate)) < videoEndTime {
                let sampleCount = min(
                    framesPerAudioBuffer,
                    firstAudioSampleIndex + audioSampleCount - nextAudioSampleIndex
                )
                let audioSampleBuffer = try Self.makeFloat32AudioSampleBuffer(
                    sampleRate: configuration.audioSampleRate,
                    channelCount: configuration.audioChannelCount,
                    startSampleIndex: nextAudioSampleIndex,
                    sampleCount: sampleCount
                )
                writer.append(sampleBuffer: audioSampleBuffer, kind: .audio)
                nextAudioSampleIndex += sampleCount
            }
        }

        try await writer.finish()

        XCTAssertTrue(recorder.segments.contains { $0.kind == .initialization })
        XCTAssertTrue(recorder.segments.contains {
            if case .media = $0.kind { true } else { false }
        })

        let outputDirectory = URL(
            fileURLWithPath: "/private/tmp/LDTXCoreTests-LargePTS-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Self.writeSegments(recorder.segments, to: outputDirectory)

        let playbackURL = try Self.writeConcatenatedPlaybackFile(in: outputDirectory)
        let playbackAsset = AVURLAsset(url: playbackURL)
        let playbackDuration = try await playbackAsset.load(.duration)
        let videoTracks = try await playbackAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await playbackAsset.loadTracks(withMediaType: .audio)
        let videoTimeRange = try await XCTUnwrap(videoTracks.first).load(.timeRange)
        let audioTimeRange = try await XCTUnwrap(audioTracks.first).load(.timeRange)

        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertLessThan(abs(videoTimeRange.start.seconds), 0.1)
        XCTAssertLessThan(abs(audioTimeRange.start.seconds), 0.1)
        XCTAssertGreaterThan(playbackDuration.seconds, 2.5)
        XCTAssertLessThan(playbackDuration.seconds, 3.5)
        XCTAssertGreaterThan(videoTimeRange.duration.seconds, 2.5)
        XCTAssertGreaterThan(audioTimeRange.duration.seconds, 2.5)
    }

    func testAudioSampleBufferNormalizerMapsSourcePTSTo48kTimeline() throws {
        let normalizer = try AudioSampleBufferNormalizer()
        let firstSource = try Self.makeAudioSampleBuffer(
            sampleRate: 44_100,
            channelCount: 1,
            startSampleIndex: 44_100 * 10,
            sampleCount: 441
        )
        let secondSource = try Self.makeAudioSampleBuffer(
            sampleRate: 44_100,
            channelCount: 1,
            startSampleIndex: 44_100 * 10 + 4_410,
            sampleCount: 441
        )

        let firstNormalized = try XCTUnwrap(normalizer.normalize(firstSource))
        let secondNormalized = try XCTUnwrap(normalizer.normalize(secondSource))
        let streamDescription = try XCTUnwrap(
            firstNormalized.formatDescription.flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
        )

        XCTAssertEqual(
            firstNormalized.presentationTimeStamp,
            CMTime(value: 480_000, timescale: 48_000)
        )
        XCTAssertEqual(streamDescription.mFormatID, kAudioFormatLinearPCM)
        XCTAssertTrue((streamDescription.mFormatFlags & kAudioFormatFlagIsFloat) != 0)
        XCTAssertEqual(streamDescription.mBitsPerChannel, 32)
        XCTAssertEqual(
            secondNormalized.presentationTimeStamp,
            CMTime(value: 484_800, timescale: 48_000)
        )
        XCTAssertGreaterThan(
            secondNormalized.presentationTimeStamp,
            CMTimeAdd(
                firstNormalized.presentationTimeStamp,
                CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(firstNormalized)), timescale: 48_000)
            )
        )
    }

    func testAudioFramePTSClockKeepsNormalizedBuffersContiguous() throws {
        let normalizer = try AudioSampleBufferNormalizer()
        let clock = try AudioFramePTSClock()
        let firstSource = try Self.makeAudioSampleBuffer(
            sampleRate: 44_100,
            channelCount: 1,
            startSampleIndex: 44_100 * 10,
            sampleCount: 441
        )
        let secondSource = try Self.makeAudioSampleBuffer(
            sampleRate: 44_100,
            channelCount: 1,
            startSampleIndex: 44_100 * 10 + 441,
            sampleCount: 441
        )

        let firstNormalized = try XCTUnwrap(normalizer.normalize(firstSource))
        let secondNormalized = try XCTUnwrap(normalizer.normalize(secondSource))
        let firstPTS = try clock.nextPresentationTime(
            anchorPresentationTime: firstNormalized.presentationTimeStamp,
            frameCount: CMSampleBufferGetNumSamples(firstNormalized)
        )
        let secondPTS = try clock.nextPresentationTime(
            anchorPresentationTime: secondNormalized.presentationTimeStamp,
            frameCount: CMSampleBufferGetNumSamples(secondNormalized)
        )

        XCTAssertEqual(firstPTS, firstNormalized.presentationTimeStamp)
        XCTAssertEqual(
            secondPTS,
            CMTimeAdd(
                firstPTS,
                CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(firstNormalized)), timescale: 48_000)
            )
        )
    }

    func testWritesSyntheticVideoFramesToMP4File() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDTXCoreTests-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let configuration = SegmentedMP4WriterConfiguration(
            width: 320,
            height: 180,
            frameRate: 30,
            videoBitRate: 800_000,
            segmentDurationSeconds: 2
        )
        let writer = try FileMP4Writer(
            outputURL: outputURL,
            configuration: configuration,
            includesAudio: false
        )

        for frameIndex in 0..<60 {
            let sampleBuffer = try Self.makeVideoSampleBuffer(
                width: configuration.width,
                height: configuration.height,
                frameIndex: frameIndex,
                frameRate: configuration.frameRate
            )
            writer.append(sampleBuffer: sampleBuffer, kind: .video)
        }

        try await writer.finish()

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = try XCTUnwrap(attributes[.size] as? UInt64)
        XCTAssertGreaterThan(fileSize, 0)
    }

    func testWritesFormulaGeneratedAudioVideoPatternsToMP4Files() async throws {
        try LDTXTestConfiguration.skipUnlessHeavyMediaTestsEnabled("formula-generated audio/video MP4 pattern matrix")

        let cases: [SyntheticMediaCase] = [
            SyntheticMediaCase(
                name: "nv12-video-range-48000-stereo",
                configuration: SegmentedMP4WriterConfiguration(
                    width: 320,
                    height: 180,
                    frameRate: 30,
                    videoBitRate: 1_500_000,
                    audioSampleRate: 48_000,
                    audioChannelCount: 2,
                    audioBitRate: 128_000,
                    segmentDurationSeconds: 2
                ),
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ),
            SyntheticMediaCase(
                name: "nv12-full-range-44100-mono",
                configuration: SegmentedMP4WriterConfiguration(
                    width: 320,
                    height: 180,
                    frameRate: 30,
                    videoBitRate: 1_500_000,
                    audioSampleRate: 44_100,
                    audioChannelCount: 1,
                    audioBitRate: 96_000,
                    segmentDurationSeconds: 2
                ),
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ),
            SyntheticMediaCase(
                name: "bgra-360p-48000-stereo",
                configuration: SegmentedMP4WriterConfiguration(
                    width: 640,
                    height: 360,
                    frameRate: 30,
                    videoBitRate: 2_500_000,
                    audioSampleRate: 48_000,
                    audioChannelCount: 2,
                    audioBitRate: 128_000,
                    segmentDurationSeconds: 2
                ),
                pixelFormat: kCVPixelFormatType_32BGRA
            )
        ]

        for testCase in cases {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LDTXCoreTests-\(testCase.name)-\(UUID().uuidString)")
                .appendingPathExtension("mp4")
            defer {
                try? FileManager.default.removeItem(at: outputURL)
            }

            let writer = try FileMP4Writer(
                outputURL: outputURL,
                configuration: testCase.configuration,
                includesAudio: true
            )
            try Self.appendSyntheticAudioVideo(
                to: writer,
                configuration: testCase.configuration,
                pixelFormat: testCase.pixelFormat,
                durationSeconds: 2
            )
            try await writer.finish()

            let asset = AVURLAsset(url: outputURL)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let fileSize = try XCTUnwrap(attributes[.size] as? UInt64)

            XCTAssertEqual(videoTracks.count, 1, testCase.name)
            XCTAssertEqual(audioTracks.count, 1, testCase.name)
            XCTAssertGreaterThan(duration.seconds, 1.8, testCase.name)
            XCTAssertGreaterThan(fileSize, 10_000, testCase.name)
            try await Self.assertSamplePresentationTimesAreStrictlyIncreasing(
                asset: asset,
                mediaType: .audio,
                label: testCase.name
            )
        }
    }

    private static func makeVideoSampleBuffer(
        width: Int,
        height: Int,
        frameIndex: Int,
        frameRate: Int,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        sourcePresentationTime: CMTime? = nil
    ) throws -> CMSampleBuffer {
        let pixelBuffer = try makePixelBuffer(
            width: width,
            height: height,
            frameIndex: frameIndex,
            pixelFormat: pixelFormat
        )
        let formatDescription = try CMVideoFormatDescription(imageBuffer: pixelBuffer)
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            presentationTimeStamp: sourcePresentationTime ?? CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(frameRate)),
            decodeTimeStamp: .invalid
        )
        return try CMSampleBuffer(
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: timing
        )
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int,
        frameIndex: Int,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let unwrappedPixelBuffer = try XCTUnwrap(pixelBuffer)

        CVPixelBufferLockBaseAddress(unwrappedPixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(unwrappedPixelBuffer, [])
        }

        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            try fillBiPlanarYUV(unwrappedPixelBuffer, width: width, height: height, frameIndex: frameIndex)
        case kCVPixelFormatType_32BGRA:
            try fillBGRA(unwrappedPixelBuffer, width: width, height: height, frameIndex: frameIndex)
        default:
            XCTFail("Unsupported synthetic pixel format: \(pixelFormat)")
        }

        return unwrappedPixelBuffer
    }

    private static func fillBiPlanarYUV(
        _ pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        frameIndex: Int
    ) throws {
        let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        let uvBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let yBuffer = try XCTUnwrap(yBaseAddress?.assumingMemoryBound(to: UInt8.self))
        let uvBuffer = try XCTUnwrap(uvBaseAddress?.assumingMemoryBound(to: UInt8.self))

        for y in 0..<height {
            for x in 0..<width {
                let wave = (x * 3 + y * 5 + frameIndex * 11) & 0xff
                let checker = ((x / 16 + y / 16 + frameIndex / 3) & 1) * 36
                yBuffer[y * yBytesPerRow + x] = UInt8(32 + ((wave + checker) % 192))
            }
        }

        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                let offset = y * uvBytesPerRow + x * 2
                uvBuffer[offset] = UInt8(64 + ((x * 7 + frameIndex * 5) % 128))
                uvBuffer[offset + 1] = UInt8(64 + ((y * 9 + frameIndex * 3) % 128))
            }
        }
    }

    private static func fillBGRA(
        _ pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        frameIndex: Int
    ) throws {
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = try XCTUnwrap(baseAddress?.assumingMemoryBound(to: UInt8.self))

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                buffer[offset] = UInt8((x * 2 + frameIndex * 5) & 0xff)
                buffer[offset + 1] = UInt8((y * 3 + frameIndex * 7) & 0xff)
                buffer[offset + 2] = UInt8((x + y + frameIndex * 11) & 0xff)
                buffer[offset + 3] = 255
            }
        }
    }

    private static func appendSyntheticAudioVideo(
        to writer: any SyntheticSampleBufferWriting,
        configuration: SegmentedMP4WriterConfiguration,
        pixelFormat: OSType,
        durationSeconds: Int
    ) throws {
        let frameCount = durationSeconds * configuration.frameRate
        let framesPerAudioBuffer = 1_024
        let audioSampleCount = durationSeconds * configuration.audioSampleRate
        var nextAudioSampleIndex = 0

        for frameIndex in 0..<frameCount {
            let videoSampleBuffer = try makeVideoSampleBuffer(
                width: configuration.width,
                height: configuration.height,
                frameIndex: frameIndex,
                frameRate: configuration.frameRate,
                pixelFormat: pixelFormat
            )
            writer.append(sampleBuffer: videoSampleBuffer, kind: .video)

            let videoEndTime = CMTime(
                value: CMTimeValue(frameIndex + 1),
                timescale: CMTimeScale(configuration.frameRate)
            )
            while nextAudioSampleIndex < audioSampleCount,
                  CMTime(value: CMTimeValue(nextAudioSampleIndex), timescale: CMTimeScale(configuration.audioSampleRate)) < videoEndTime {
                let sampleCount = min(framesPerAudioBuffer, audioSampleCount - nextAudioSampleIndex)
                let audioSampleBuffer = try makeAudioSampleBuffer(
                    sampleRate: configuration.audioSampleRate,
                    channelCount: configuration.audioChannelCount,
                    startSampleIndex: nextAudioSampleIndex,
                    sampleCount: sampleCount
                )
                writer.append(sampleBuffer: audioSampleBuffer, kind: .audio)
                nextAudioSampleIndex += sampleCount
            }
        }
    }

    private static func makeAudioSampleBuffer(
        sampleRate: Int,
        channelCount: Int,
        startSampleIndex: Int,
        sampleCount: Int
    ) throws -> CMSampleBuffer {
        let bytesPerSample = MemoryLayout<Int16>.size
        let bytesPerFrame = bytesPerSample * channelCount
        var data = Data(count: sampleCount * bytesPerFrame)
        data.withUnsafeMutableBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for frame in 0..<sampleCount {
                let absoluteSample = startSampleIndex + frame
                for channel in 0..<channelCount {
                    let frequency = Double(channel == 0 ? 440 : 660)
                    let phase = 2.0 * Double.pi * frequency * Double(absoluteSample) / Double(sampleRate)
                    let sweep = sin(2.0 * Double.pi * Double(absoluteSample % sampleRate) / Double(sampleRate))
                    let value = (sin(phase) * 0.55 + sweep * 0.15) * Double(Int16.max)
                    samples[frame * channelCount + channel] = Int16(max(Double(Int16.min), min(Double(Int16.max), value)))
                }
            }
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = data.withUnsafeBytes { rawBuffer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: data.count,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: data.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        XCTAssertEqual(blockStatus, kCMBlockBufferNoErr)
        let unwrappedBlockBuffer = try XCTUnwrap(blockBuffer)
        data.withUnsafeBytes { rawBuffer in
            let status = CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: unwrappedBlockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
            XCTAssertEqual(status, kCMBlockBufferNoErr)
        }

        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(bytesPerSample * 8),
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(formatStatus, noErr)
        let unwrappedFormatDescription = try XCTUnwrap(formatDescription)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(startSampleIndex), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: unwrappedBlockBuffer,
            formatDescription: unwrappedFormatDescription,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(sampleStatus, noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    private static func makeFloat32AudioSampleBuffer(
        sampleRate: Int,
        channelCount: Int,
        startSampleIndex: Int,
        sampleCount: Int
    ) throws -> CMSampleBuffer {
        let bytesPerSample = MemoryLayout<Float32>.size
        let bytesPerFrame = bytesPerSample * channelCount
        var data = Data(count: sampleCount * bytesPerFrame)
        data.withUnsafeMutableBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Float32.self)
            for frame in 0..<sampleCount {
                let absoluteSample = startSampleIndex + frame
                for channel in 0..<channelCount {
                    let frequency = Double(channel == 0 ? 440 : 660)
                    let phase = 2.0 * Double.pi * frequency * Double(absoluteSample) / Double(sampleRate)
                    samples[frame * channelCount + channel] = Float32(sin(phase) * 0.35)
                }
            }
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(blockStatus, kCMBlockBufferNoErr)
        let unwrappedBlockBuffer = try XCTUnwrap(blockBuffer)
        data.withUnsafeBytes { rawBuffer in
            let status = CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: unwrappedBlockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
            XCTAssertEqual(status, kCMBlockBufferNoErr)
        }

        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(bytesPerSample * 8),
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(formatStatus, noErr)
        let unwrappedFormatDescription = try XCTUnwrap(formatDescription)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(startSampleIndex), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: unwrappedBlockBuffer,
            formatDescription: unwrappedFormatDescription,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(sampleStatus, noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    private static func writeConcatenatedPlaybackFile(in directory: URL) throws -> URL {
        let initializationURL = directory.appendingPathComponent("init.mp4")
        let mediaURLs = try mediaSegmentURLs(in: directory)

        XCTAssertFalse(mediaURLs.isEmpty)

        var playbackData = try Data(contentsOf: initializationURL)
        for mediaURL in mediaURLs {
            playbackData.append(try Data(contentsOf: mediaURL))
        }

        let playbackURL = directory.appendingPathComponent("playback.mp4")
        try playbackData.write(to: playbackURL, options: .atomic)
        return playbackURL
    }

    private static func writeSegments(
        _ segments: [SegmentedMP4Segment],
        to directory: URL
    ) throws {
        for segment in segments {
            let fileName = switch segment.kind {
            case .initialization:
                "init.mp4"
            case let .media(number):
                String(format: "media%09d.mp4", number)
            }
            try segment.data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        }
    }

    private static func mediaSegmentURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { url in
            url.lastPathComponent.hasPrefix("media") && url.pathExtension == "mp4"
        }
        .sorted { lhs, rhs in
            lhs.lastPathComponent < rhs.lastPathComponent
        }
    }

    private static func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.size] as? UInt64)
    }

    private static func assertSamplePresentationTimesAreStrictlyIncreasing(
        asset: AVAsset,
        mediaType: AVMediaType,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let tracks = try await asset.loadTracks(withMediaType: mediaType)
        let track = try XCTUnwrap(tracks.first, label, file: file, line: line)
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any]? = if mediaType == .audio {
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false
            ]
        } else {
            nil
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        XCTAssertTrue(reader.canAdd(output), label, file: file, line: line)
        reader.add(output)
        XCTAssertTrue(reader.startReading(), label, file: file, line: line)

        var previousPresentationTime: CMTime?
        var sampleBufferCount = 0
        var validPresentationTimeCount = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            let outputPresentationTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            let presentationTime = outputPresentationTime.isValid
                ? outputPresentationTime
                : sampleBuffer.presentationTimeStamp
            guard presentationTime.isValid else {
                continue
            }
            if let previousPresentationTime {
                XCTAssertGreaterThan(
                    presentationTime,
                    previousPresentationTime,
                    "\(label): \(mediaType.rawValue) sample PTS must be strictly increasing",
                    file: file,
                    line: line
                )
            }
            previousPresentationTime = presentationTime
            sampleBufferCount += 1
            validPresentationTimeCount += 1
        }

        if reader.status == .failed {
            throw try XCTUnwrap(reader.error, label, file: file, line: line)
        }
        XCTAssertGreaterThan(sampleBufferCount, 0, label, file: file, line: line)
        XCTAssertGreaterThan(validPresentationTimeCount, 1, label, file: file, line: line)
    }

    private static func videoFormatDescription(for sampleBuffer: CMSampleBuffer) -> String {
        guard let imageBuffer = sampleBuffer.imageBuffer,
              let formatDescription = sampleBuffer.formatDescription else {
            return "unavailable"
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        let timing = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        return [
            "width=\(dimensions.width)",
            "height=\(dimensions.height)",
            "pixelFormat=\(fourCharacterCodeString(pixelFormat))(\(pixelFormat))",
            "planeCount=\(CVPixelBufferGetPlaneCount(imageBuffer))",
            "bytesPerRow=\(bytesPerRowDescription(imageBuffer))",
            "pts=\(timing.seconds)s",
            "duration=\(duration.seconds)s"
        ].joined(separator: ", ")
    }

    private static func writerConfigurationDescription(_ configuration: SegmentedMP4WriterConfiguration) -> String {
        [
            "width=\(configuration.width)",
            "height=\(configuration.height)",
            "frameRate=\(configuration.frameRate)",
            "videoBitRate=\(configuration.videoBitRate)",
            "segmentDurationSeconds=\(configuration.segmentDurationSeconds)",
            "timescale=\(configuration.timescale)",
            "startNumber=\(configuration.startNumber)"
        ].joined(separator: ", ")
    }

    private static func bytesPerRowDescription(_ imageBuffer: CVPixelBuffer) -> String {
        let planeCount = CVPixelBufferGetPlaneCount(imageBuffer)
        if planeCount == 0 {
            return "\(CVPixelBufferGetBytesPerRow(imageBuffer))"
        }
        return (0..<planeCount)
            .map { "\($0):\(CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, $0))" }
            .joined(separator: "/")
    }

    private static func fourCharacterCodeString(_ value: OSType) -> String {
        let scalars = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        let characters = scalars.map { byte -> Character in
            if byte >= 32, byte <= 126 {
                return Character(UnicodeScalar(byte))
            }
            return "."
        }
        return String(characters)
    }

}

private protocol SyntheticSampleBufferWriting: AnyObject {
    func append(sampleBuffer: CMSampleBuffer, kind: SegmentedMP4SampleKind)
}

extension FileMP4Writer: SyntheticSampleBufferWriting {}
extension SegmentedMP4Writer: SyntheticSampleBufferWriting {}

private extension Array where Element == SegmentedMP4Segment {
    var mediaSegmentCount: Int {
        count { segment in
            if case .media = segment.kind {
                true
            } else {
                false
            }
        }
    }
}

private struct SyntheticMediaCase {
    var name: String
    var configuration: SegmentedMP4WriterConfiguration
    var pixelFormat: OSType
}

private final class SegmentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSegments: [SegmentedMP4Segment] = []

    var segments: [SegmentedMP4Segment] {
        lock.withLock { storedSegments }
    }

    func append(_ segment: SegmentedMP4Segment) {
        lock.withLock {
            storedSegments.append(segment)
        }
    }
}
