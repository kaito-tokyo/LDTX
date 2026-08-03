// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXMP4

public enum DASHLocalFilePipelineEvent: Equatable, Sendable {
    case initializationWritten(URL, byteCount: Int)
    case mediaSegmentWritten(URL, number: Int, byteCount: Int)
}

public enum DASHLocalFilePipelineError: Error, Equatable, LocalizedError {
    case mediaSegmentBeforeInitialization(Int)
    case mediaSegmentMissingTiming(Int)
    case noncontiguousMediaSegment(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case let .mediaSegmentBeforeInitialization(number):
            "DASH media segment \(number) was produced before the initialization segment."
        case let .mediaSegmentMissingTiming(number):
            "DASH media segment \(number) does not contain valid presentation timing."
        case let .noncontiguousMediaSegment(expected, actual):
            "DASH media segment numbering is not contiguous; expected \(expected), got \(actual)."
        }
    }
}

public final class DASHLocalFilePipeline: @unchecked Sendable {
    private let directory: URL
    private let manifestFileName: String
    private let baseManifestConfiguration: DASHManifestConfiguration
    private var wroteInitialization = false
    private var segmentTimeline: [DASHSegmentTimelineEntry] = []
    private let lock = NSLock()

    public init(
        directory: URL,
        manifestFileName: String = "manifest.mpd",
        manifestConfiguration: DASHManifestConfiguration
    ) {
        self.directory = directory
        self.manifestFileName = manifestFileName
        baseManifestConfiguration = manifestConfiguration
    }

    public func write(_ segment: SegmentedMP4Segment) throws -> DASHLocalFilePipelineEvent {
        try lock.withLock {
            try writeLocked(segment)
        }
    }

    private func writeLocked(_ segment: SegmentedMP4Segment) throws -> DASHLocalFilePipelineEvent {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        switch segment.kind {
        case .initialization:
            let initializationURL = directory.appendingPathComponent("init.mp4")
            try segment.data.write(to: initializationURL, options: .atomic)
            wroteInitialization = true
            return .initializationWritten(initializationURL, byteCount: segment.data.count)

        case let .media(number):
            guard wroteInitialization else {
                throw DASHLocalFilePipelineError.mediaSegmentBeforeInitialization(number)
            }
            let entry = try timelineEntry(for: segment, number: number)
            let candidateTimeline = segmentTimeline + [entry]
            let candidateManifestData = try manifestData(segmentTimeline: candidateTimeline)
            let url = directory.appendingPathComponent(Self.mediaFileName(number: number))
            try segment.data.write(to: url, options: .atomic)
            try candidateManifestData.write(
                to: directory.appendingPathComponent(manifestFileName), options: .atomic)
            segmentTimeline = candidateTimeline
            return .mediaSegmentWritten(url, number: number, byteCount: segment.data.count)
        }
    }

    private func manifestData(segmentTimeline: [DASHSegmentTimelineEntry]) throws -> Data {
        var manifestConfiguration = baseManifestConfiguration
        manifestConfiguration.kind = .static
        manifestConfiguration.initialization = .url("init.mp4")
        manifestConfiguration.startNumber = segmentTimeline.first?.number
            ?? manifestConfiguration.startNumber
        manifestConfiguration.segmentTimeline = segmentTimeline
        let lastEnd = segmentTimeline.map { $0.startTimeSeconds + $0.durationSeconds }.max()
        manifestConfiguration.mediaPresentationDurationSeconds = lastEnd
        return try Data(DASHManifestGenerator.xml(configuration: manifestConfiguration).utf8)
    }

    private func timelineEntry(
        for segment: SegmentedMP4Segment,
        number: Int
    ) throws -> DASHSegmentTimelineEntry {
        guard let start = segment.earliestPresentationTimeSeconds,
            let duration = segment.durationSeconds,
            start.isFinite, start >= 0, duration.isFinite, duration > 0
        else { throw DASHLocalFilePipelineError.mediaSegmentMissingTiming(number) }
        if let last = segmentTimeline.last, number != last.number + 1 {
            throw DASHLocalFilePipelineError.noncontiguousMediaSegment(
                expected: last.number + 1, actual: number)
        }
        return DASHSegmentTimelineEntry(
            number: number, startTimeSeconds: start, durationSeconds: duration)
    }

    private static func mediaFileName(number: Int) -> String {
        "media\(String(format: "%09d", number)).mp4"
    }
}
