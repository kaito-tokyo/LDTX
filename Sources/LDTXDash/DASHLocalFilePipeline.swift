// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXMP4

public enum DASHLocalFilePipelineEvent: Equatable, Sendable {
    case manifestWritten(URL, byteCount: Int, initializationURL: URL, initializationByteCount: Int)
    case mediaSegmentWritten(URL, number: Int, byteCount: Int)
}

public enum DASHLocalFilePipelineError: Error, Equatable, LocalizedError {
    case mediaSegmentBeforeInitialization(Int)

    public var errorDescription: String? {
        switch self {
        case let .mediaSegmentBeforeInitialization(number):
            "DASH media segment \(number) was produced before the initialization segment."
        }
    }
}

public final class DASHLocalFilePipeline: @unchecked Sendable {
    private let directory: URL
    private let manifestFileName: String
    private let baseManifestConfiguration: DASHManifestConfiguration
    private var wroteManifest = false
    private var highestMediaSegmentNumber = 0
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
            let url = directory.appendingPathComponent(manifestFileName)
            let initializationURL = directory.appendingPathComponent("init.mp4")
            try segment.data.write(to: initializationURL, options: .atomic)
            let data = try manifestData()
            try data.write(to: url, options: .atomic)
            wroteManifest = true
            return .manifestWritten(
                url,
                byteCount: data.count,
                initializationURL: initializationURL,
                initializationByteCount: segment.data.count
            )

        case let .media(number):
            guard wroteManifest else {
                throw DASHLocalFilePipelineError.mediaSegmentBeforeInitialization(number)
            }
            let url = directory.appendingPathComponent(Self.mediaFileName(number: number))
            try segment.data.write(to: url, options: .atomic)
            highestMediaSegmentNumber = max(highestMediaSegmentNumber, number)
            try manifestData().write(to: directory.appendingPathComponent(manifestFileName), options: .atomic)
            return .mediaSegmentWritten(url, number: number, byteCount: segment.data.count)
        }
    }

    private func manifestData() throws -> Data {
        var manifestConfiguration = baseManifestConfiguration
        manifestConfiguration.kind = .static
        manifestConfiguration.initialization = .url("init.mp4")
        if highestMediaSegmentNumber > 0 {
            let segmentCount = highestMediaSegmentNumber - manifestConfiguration.startNumber + 1
            manifestConfiguration.mediaPresentationDurationSeconds = max(
                1,
                segmentCount * manifestConfiguration.segmentDurationSeconds
            )
        } else {
            manifestConfiguration.mediaPresentationDurationSeconds = nil
        }
        return try Data(DASHManifestGenerator.xml(configuration: manifestConfiguration).utf8)
    }

    private static func mediaFileName(number: Int) -> String {
        "media\(String(format: "%09d", number)).mp4"
    }
}
