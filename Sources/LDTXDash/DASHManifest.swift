// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXSupport

public struct DASHManifestConfiguration: Equatable, Sendable {
    public var kind: DASHManifestKind
    public var availabilityStartTime: Date
    public var mediaPresentationDurationSeconds: Int?
    public var minimumUpdatePeriodSeconds: Int
    public var minBufferTimeSeconds: Int
    public var timeShiftBufferDepthSeconds: Int
    public var timescale: Int
    public var segmentDurationSeconds: Int
    public var startNumber: Int
    public var mediaTemplate: String
    public var initialization: DASHInitializationReference
    public var representation: DASHRepresentation

    public init(
        kind: DASHManifestKind = .dynamic,
        availabilityStartTime: Date = Date(),
        mediaPresentationDurationSeconds: Int? = nil,
        minimumUpdatePeriodSeconds: Int = 5,
        minBufferTimeSeconds: Int = 4,
        timeShiftBufferDepthSeconds: Int = 60,
        timescale: Int = 1_000,
        segmentDurationSeconds: Int = 2,
        startNumber: Int = 1,
        mediaTemplate: String = "media$Number%09d$.mp4",
        initialization: DASHInitializationReference,
        representation: DASHRepresentation = .default1080p60
    ) {
        self.kind = kind
        self.availabilityStartTime = availabilityStartTime
        self.mediaPresentationDurationSeconds = mediaPresentationDurationSeconds
        self.minimumUpdatePeriodSeconds = minimumUpdatePeriodSeconds
        self.minBufferTimeSeconds = minBufferTimeSeconds
        self.timeShiftBufferDepthSeconds = timeShiftBufferDepthSeconds
        self.timescale = timescale
        self.segmentDurationSeconds = segmentDurationSeconds
        self.startNumber = startNumber
        self.mediaTemplate = mediaTemplate
        self.initialization = initialization
        self.representation = representation
    }
}

public enum DASHManifestKind: Equatable, Sendable {
    case dynamic
    case `static`
}

public enum DASHInitializationReference: Equatable, Sendable {
    case embedded(data: Data, mimeType: String = "video/mp4")
    case url(String)
}

public struct DASHRepresentation: Equatable, Sendable {
    public var id: String
    public var bandwidth: Int
    public var width: Int
    public var height: Int
    public var frameRate: String
    public var mimeType: String
    public var codecs: String
    public var audioSamplingRate: Int

    public init(
        id: String,
        bandwidth: Int,
        width: Int,
        height: Int,
        frameRate: String,
        mimeType: String = "video/mp4",
        codecs: String,
        audioSamplingRate: Int = 48_000
    ) {
        self.id = id
        self.bandwidth = bandwidth
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.mimeType = mimeType
        self.codecs = codecs
        self.audioSamplingRate = audioSamplingRate
    }

    public static let default1080p60 = DASHRepresentation(
        id: "1080p60",
        bandwidth: 6_000_000,
        width: 1_920,
        height: 1_080,
        frameRate: "60",
        codecs: "avc1.64002a,mp4a.40.2"
    )
}

public enum DASHManifestError: Error, Equatable, LocalizedError {
    case invalidMinimumUpdatePeriod(Int)
    case invalidDuration
    case invalidStartNumber(Int)
    case initializationDataTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidMinimumUpdatePeriod(value):
            "The MPD minimumUpdatePeriod must be between 1 and 60 seconds; got \(value)."
        case .invalidDuration:
            "The MPD segment duration and timescale must be positive."
        case let .invalidStartNumber(value):
            "The MPD startNumber must be positive; got \(value)."
        case let .initializationDataTooLarge(byteCount):
            "Embedded initialization data is too large for YouTube DASH ingest: \(byteCount) bytes."
        }
    }
}

public enum DASHManifestGenerator {
    public static func xml(configuration: DASHManifestConfiguration) throws -> String {
        try validate(configuration)

        let segmentDuration = configuration.segmentDurationSeconds * configuration.timescale
        let mpdAttributes = Self.mpdAttributes(configuration)
        let initialization = try initializationAttribute(configuration.initialization)
        let representation = configuration.representation

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-live:2011" \(mpdAttributes)>
          <Period id="live" start="PT0S">
            <AdaptationSet id="0" mimeType="\(XMLAttributeEscaper.escape(representation.mimeType))" codecs="\(XMLAttributeEscaper.escape(representation.codecs))" segmentAlignment="true" subsegmentAlignment="true" startWithSAP="1">
              <ContentComponent id="1" contentType="video"/>
              <ContentComponent id="2" contentType="audio"/>
              <SegmentTemplate timescale="\(configuration.timescale)" duration="\(segmentDuration)" startNumber="\(configuration.startNumber)" media="\(XMLAttributeEscaper.escape(configuration.mediaTemplate))" initialization="\(initialization)"/>
              <Representation id="\(XMLAttributeEscaper.escape(representation.id))" bandwidth="\(representation.bandwidth)" width="\(representation.width)" height="\(representation.height)" frameRate="\(XMLAttributeEscaper.escape(representation.frameRate))" audioSamplingRate="\(representation.audioSamplingRate)"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """
    }

    private static func validate(_ configuration: DASHManifestConfiguration) throws {
        guard (1...60).contains(configuration.minimumUpdatePeriodSeconds) else {
            throw DASHManifestError.invalidMinimumUpdatePeriod(configuration.minimumUpdatePeriodSeconds)
        }
        guard configuration.segmentDurationSeconds > 0, configuration.timescale > 0 else {
            throw DASHManifestError.invalidDuration
        }
        guard configuration.startNumber > 0 else {
            throw DASHManifestError.invalidStartNumber(configuration.startNumber)
        }
        if case let .embedded(data, _) = configuration.initialization, data.count > 100_000 {
            throw DASHManifestError.initializationDataTooLarge(data.count)
        }
    }

    private static func mpdAttributes(_ configuration: DASHManifestConfiguration) -> String {
        switch configuration.kind {
        case .dynamic:
            let availabilityStartTime = ISO8601UTCFormatter.string(from: configuration.availabilityStartTime)
            return #"type="dynamic" minBufferTime="PT\#(configuration.minBufferTimeSeconds)S" minimumUpdatePeriod="PT\#(configuration.minimumUpdatePeriodSeconds)S" timeShiftBufferDepth="PT\#(configuration.timeShiftBufferDepthSeconds)S" availabilityStartTime="\#(availabilityStartTime)""#
        case .static:
            let duration = configuration.mediaPresentationDurationSeconds.map { #" mediaPresentationDuration="PT\#($0)S""# } ?? ""
            return #"type="static" minBufferTime="PT\#(configuration.minBufferTimeSeconds)S"\#(duration)"#
        }
    }

    private static func initializationAttribute(_ reference: DASHInitializationReference) throws -> String {
        switch reference {
        case let .embedded(data, mimeType):
            let encoded = data.base64EncodedString()
            return "data:\(XMLAttributeEscaper.escape(mimeType));base64,\(encoded)"
        case let .url(url):
            return XMLAttributeEscaper.escape(url)
        }
    }
}
