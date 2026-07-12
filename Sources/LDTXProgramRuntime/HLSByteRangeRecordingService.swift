// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import LDTXMP4
import LDTXSupport
import OSLog

private let hlsByteRangeRecordingLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "HLSByteRangeRecording"
)

struct HLSByteRangeRecordingAudioTrack: Sendable {
    var id: String
    var displayName: String
    var fileNameStem: String
}

struct HLSByteRangeRecordingPackageConfiguration: Sendable {
    var directory: URL
    var recordID: String
    var targetDurationSeconds: Int
    var videoCodecs: String
    var audioCodecs: String
    var bandwidth: Int
    var includesMainAudioTrack: Bool
    var audioTracks: [HLSByteRangeRecordingAudioTrack]
}

final class HLSByteRangeRecordingPackage: @unchecked Sendable {
    let directory: URL
    let recordID: String
    let mainTrack: HLSByteRangeTrackRecorder
    let audioTracks: [String: HLSByteRangeTrackRecorder]

    init(configuration: HLSByteRangeRecordingPackageConfiguration) throws {
        directory = configuration.directory
        recordID = configuration.recordID
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        mainTrack = try HLSByteRangeTrackRecorder(
            directory: directory,
            mediaFileName: "main-stream.mp4",
            playlistFileName: "main-stream.m3u8",
            targetDurationSeconds: configuration.targetDurationSeconds
        )

        var audioTracks: [String: HLSByteRangeTrackRecorder] = [:]
        for audioTrack in configuration.audioTracks {
            audioTracks[audioTrack.id] = try HLSByteRangeTrackRecorder(
                directory: directory,
                mediaFileName: "\(audioTrack.fileNameStem).mp4",
                playlistFileName: "\(audioTrack.fileNameStem).m3u8",
                targetDurationSeconds: configuration.targetDurationSeconds
            )
        }
        self.audioTracks = audioTracks

        try writeMasterPlaylist(configuration: configuration)
    }

    func finish() {
        mainTrack.finish()
        for recorder in audioTracks.values {
            recorder.finish()
        }
    }

    private func writeMasterPlaylist(configuration: HLSByteRangeRecordingPackageConfiguration) throws {
        let audioGroupID = "audio"
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7"
        ]

        for (index, audioTrack) in configuration.audioTracks.enumerated() {
            let escapedName = Self.escapeAttribute(audioTrack.displayName)
            let defaultValue = index == 0 ? "YES" : "NO"
            lines.append(
                "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"\(audioGroupID)\",NAME=\"\(escapedName)\",DEFAULT=\(defaultValue),AUTOSELECT=YES,URI=\"\(audioTrack.fileNameStem).m3u8\""
            )
        }

        let codecs: String
        if configuration.includesMainAudioTrack || !configuration.audioTracks.isEmpty {
            codecs = "\(configuration.videoCodecs),\(configuration.audioCodecs)"
        } else {
            codecs = configuration.videoCodecs
        }

        var streamInfo = "#EXT-X-STREAM-INF:BANDWIDTH=\(configuration.bandwidth),CODECS=\"\(codecs)\""
        if !configuration.audioTracks.isEmpty {
            streamInfo += ",AUDIO=\"\(audioGroupID)\""
        }
        lines.append(streamInfo)
        lines.append("main-stream.m3u8")
        lines.append("")

        let url = directory.appendingPathComponent("index.m3u8")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

final class HLSByteRangeTrackRecorder: @unchecked Sendable {
    private let directory: URL
    private let mediaURL: URL
    private let playlistURL: URL
    private let mediaFileName: String
    private let targetDurationSeconds: Int
    private let lock = NSLock()

    private var byteOffset = 0
    private var didWriteEndList = false

    init(
        directory: URL,
        mediaFileName: String,
        playlistFileName: String,
        targetDurationSeconds: Int
    ) throws {
        self.directory = directory
        self.mediaFileName = mediaFileName
        mediaURL = directory.appendingPathComponent(mediaFileName)
        playlistURL = directory.appendingPathComponent(playlistFileName)
        self.targetDurationSeconds = targetDurationSeconds

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mediaURL.path, contents: nil)
        try Self.playlistHeader(targetDurationSeconds: targetDurationSeconds)
            .write(to: playlistURL, atomically: true, encoding: .utf8)
    }

    func write(_ segment: SegmentedMP4Segment) throws {
        try lock.withLock {
            guard !didWriteEndList else { return }

            let offset = byteOffset
            try append(segment.data)
            byteOffset += segment.data.count

            switch segment.kind {
            case .initialization:
                let line = "#EXT-X-MAP:URI=\"\(mediaFileName)\",BYTERANGE=\"\(segment.data.count)@\(offset)\"\n"
                try appendPlaylist(line)

            case .media:
                let duration = max(segment.durationSeconds ?? Double(targetDurationSeconds), 0.001)
                let lines = [
                    "#EXTINF:\(String(format: "%.5f", duration)),",
                    "#EXT-X-BYTERANGE:\(segment.data.count)@\(offset)",
                    mediaFileName,
                    ""
                ].joined(separator: "\n")
                try appendPlaylist(lines)
            }
        }
    }

    func finish() {
        lock.withLock {
            guard !didWriteEndList else { return }
            didWriteEndList = true
            try? appendPlaylist("#EXT-X-ENDLIST\n")
        }
    }

    private func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: mediaURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func appendPlaylist(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: playlistURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private static func playlistHeader(targetDurationSeconds: Int) -> String {
        """
        #EXTM3U
        #EXT-X-TARGETDURATION:\(targetDurationSeconds)
        #EXT-X-VERSION:7
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-INDEPENDENT-SEGMENTS

        """
    }
}

final class AudioOnlySegmentedMP4Writer: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    typealias SegmentHandler = @Sendable (SegmentedMP4Segment) -> Void

    private let assetWriter: AVAssetWriter
    private let audioInput: AVAssetWriterInput
    private let onSegment: SegmentHandler

    private var didStartSession = false
    private var nextSegmentNumber = 1

    init(
        firstSampleBuffer: CMSampleBuffer,
        segmentDurationSeconds: Int,
        onSegment: @escaping SegmentHandler
    ) throws {
        self.onSegment = onSegment
        assetWriter = AVAssetWriter(contentType: .mpeg4Movie)
        assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
        assetWriter.preferredOutputSegmentInterval = CMTime(
            seconds: Double(segmentDurationSeconds),
            preferredTimescale: 1
        )
        assetWriter.initialSegmentStartTime = .zero

        audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: Self.outputSettings(for: firstSampleBuffer)
        )
        audioInput.expectsMediaDataInRealTime = true

        super.init()

        assetWriter.delegate = self
        guard assetWriter.canAdd(audioInput) else {
            throw AudioOnlySegmentedMP4WriterError.cannotAddAudioInput
        }
        assetWriter.add(audioInput)
        guard assetWriter.startWriting() else {
            throw AudioOnlySegmentedMP4WriterError.startWritingFailed(
                assetWriter.error?.localizedDescription ?? "unknown"
            )
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              assetWriter.status == .writing,
              audioInput.isReadyForMoreMediaData else {
            return
        }

        if !didStartSession {
            assetWriter.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            didStartSession = true
        }

        _ = audioInput.append(sampleBuffer)
    }

    func finish(
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        guard assetWriter.status == .writing else {
            completionHandler(.success(()))
            return
        }
        audioInput.markAsFinished()
        assetWriter.finishWriting { [self] in
            if assetWriter.status == .failed {
                completionHandler(.failure(AudioOnlySegmentedMP4WriterError.writerFailed(
                    assetWriter.error?.localizedDescription ?? "unknown"
                )))
            } else {
                completionHandler(.success(()))
            }
        }
    }

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        switch segmentType {
        case .initialization:
            onSegment(SegmentedMP4Segment(kind: .initialization, data: segmentData))
        case .separable:
            let number = nextSegmentNumber
            nextSegmentNumber += 1
            onSegment(SegmentedMP4Segment(
                kind: .media(number: number),
                data: segmentData,
                durationSeconds: Self.durationSeconds(from: segmentReport)
            ))
        @unknown default:
            return
        }
    }

    private static func outputSettings(for sampleBuffer: CMSampleBuffer) -> [String: Any] {
        let description = sampleBuffer.formatDescription
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sampleRate = description?.mSampleRate ?? 48_000
        let channelCount = description.map { Int($0.mChannelsPerFrame) } ?? 2
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: max(channelCount, 1),
            AVEncoderBitRateKey: 128_000
        ]
    }

    private static func durationSeconds(from segmentReport: AVAssetSegmentReport?) -> Double? {
        segmentReport?.trackReports
            .map(\.duration.seconds)
            .filter { $0.isFinite && $0 > 0 }
            .max()
    }
}

enum AudioOnlySegmentedMP4WriterError: Error, LocalizedError {
    case cannotAddAudioInput
    case startWritingFailed(String)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotAddAudioInput:
            "The audio-only fragmented MP4 writer could not add the audio input."
        case let .startWritingFailed(reason):
            "The audio-only fragmented MP4 writer could not start writing: \(reason)"
        case let .writerFailed(reason):
            "The audio-only fragmented MP4 writer failed: \(reason)"
        }
    }
}

final class AudioSideStreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let segmentDurationSeconds: Int
    private let normalizer: AudioSampleBufferNormalizer
    private let onInitializationSegment: @Sendable (Data) -> Void
    private let segmentPipeline: AudioSideStreamSegmentPipeline
    private var trackRecorder: HLSByteRangeTrackRecorder
    private var writer: AudioOnlySegmentedMP4Writer?
    private var latestInitializationSegment: SegmentedMP4Segment?
    private var isFinishing = false

    init(
        trackRecorder: HLSByteRangeTrackRecorder,
        segmentDurationSeconds: Int,
        onInitializationSegment: @escaping @Sendable (Data) -> Void = { _ in }
    ) throws {
        self.trackRecorder = trackRecorder
        self.segmentDurationSeconds = segmentDurationSeconds
        self.onInitializationSegment = onInitializationSegment
        normalizer = try AudioSampleBufferNormalizer()
        segmentPipeline = AudioSideStreamSegmentPipeline()
        segmentPipeline.start { [weak self] segment in
            try self?.write(segment)
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        let normalizedSampleBuffer: CMSampleBuffer
        do {
            guard let normalized = try normalizer.normalize(sampleBuffer) else { return }
            normalizedSampleBuffer = normalized
        } catch {
            let nsError = error as NSError
            hlsByteRangeRecordingLogger.error("Audio side stream 48 kHz normalization failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)")
            return
        }

        lock.lock()
        defer { lock.unlock() }
        guard !isFinishing else { return }

        do {
            if writer == nil {
                writer = try AudioOnlySegmentedMP4Writer(
                    firstSampleBuffer: normalizedSampleBuffer,
                    segmentDurationSeconds: segmentDurationSeconds,
                    onSegment: { [weak self] segment in
                        self?.segmentPipeline.yield(segment)
                    }
                )
            }
            writer?.append(normalizedSampleBuffer)
        } catch {
            let nsError = error as NSError
            hlsByteRangeRecordingLogger.error("Audio side stream append failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)")
            writer = nil
        }
    }

    func rotate(to trackRecorder: HLSByteRangeTrackRecorder) throws {
        try segmentPipeline.perform { [self] in
            let initializationSegment = lock.withLock { () -> SegmentedMP4Segment? in
                self.trackRecorder = trackRecorder
                return latestInitializationSegment
            }
            if let initializationSegment {
                try trackRecorder.write(initializationSegment)
            }
        }
    }

    func cachedInitializationSegmentData() -> Data? {
        lock.withLock {
            latestInitializationSegment?.data
        }
    }

    func finish(completionHandler: @escaping @Sendable () -> Void = {}) {
        let resources = lock.withLock { () -> (
            writer: AudioOnlySegmentedMP4Writer?,
            trackRecorder: HLSByteRangeTrackRecorder
        )? in
            guard !isFinishing else { return nil }
            isFinishing = true
            return (writer, trackRecorder)
        }
        guard let resources else {
            completionHandler()
            return
        }
        let finishPipeline: @Sendable () -> Void = { [self] in
            segmentPipeline.finish {
                resources.trackRecorder.finish()
                withExtendedLifetime(resources.writer) {}
                completionHandler()
            }
        }
        guard let writer = resources.writer else {
            finishPipeline()
            return
        }
        writer.finish { result in
            if case let .failure(error) = result {
                let nsError = error as NSError
                hlsByteRangeRecordingLogger.error("Audio side stream finish failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)")
            }
            finishPipeline()
        }
    }

    private func write(_ segment: SegmentedMP4Segment) throws {
        let trackRecorder = lock.withLock { () -> HLSByteRangeTrackRecorder in
            if case .initialization = segment.kind {
                latestInitializationSegment = segment
            }
            return self.trackRecorder
        }
        if case .initialization = segment.kind {
            onInitializationSegment(segment.data)
        }
        try trackRecorder.write(segment)
    }

}

final class AudioSideStreamSegmentPipeline: @unchecked Sendable {
    typealias Write = @Sendable (SegmentedMP4Segment) throws -> Void

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.AudioSideStreamSegmentPipeline")
    private var write: Write?
    private var isFinishing = false

    func start(write: @escaping Write) {
        lock.withLock {
            guard self.write == nil, !isFinishing else { return }
            self.write = write
        }
    }

    func yield(_ segment: SegmentedMP4Segment) {
        lock.withLock {
            guard !isFinishing else { return }
            queue.async { [self] in
                do {
                    try write?(segment)
                } catch {
                    let nsError = error as NSError
                    hlsByteRangeRecordingLogger.error("Audio side stream segment write failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)")
                }
            }
        }
    }

    func drain(completionHandler: @escaping @Sendable () -> Void) {
        queue.async(execute: completionHandler)
    }

    func perform(_ operation: @escaping @Sendable () throws -> Void) throws {
        try queue.sync(execute: operation)
    }

    func finish(completionHandler: @escaping @Sendable () -> Void = {}) {
        let shouldFinish = lock.withLock { () -> Bool in
            guard !isFinishing else { return false }
            isFinishing = true
            return true
        }
        guard shouldFinish else {
            queue.async(execute: completionHandler)
            return
        }
        queue.async { [self] in
            lock.withLock { write = nil }
            completionHandler()
        }
    }
}
