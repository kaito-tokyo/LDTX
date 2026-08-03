// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import LDTXMP4
import LDTXRecording
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
  private let configurationLock = NSLock()
  private var configuration: HLSByteRangeRecordingPackageConfiguration
  private let finalizedMarkerURL: URL

  init(configuration: HLSByteRangeRecordingPackageConfiguration) throws {
    directory = configuration.directory
    recordID = configuration.recordID
    self.configuration = configuration
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    finalizedMarkerURL = directory.appendingPathComponent(
      RecordingPackage.finalizedMarkerFileName
    )
    if FileManager.default.fileExists(atPath: finalizedMarkerURL.path) {
      try FileManager.default.removeItem(at: finalizedMarkerURL)
    }
    try RecordingPackageInfo.data(
      identifier: configuration.recordID,
      mainMediaFile: "output-video.mp4",
      audioTracks: configuration.audioTracks.map { track in
        RecordingPackageInfoAudioTrack(
          identifier: track.id,
          name: track.displayName,
          mediaFile: "\(track.fileNameStem).mp4"
        )
      }
    ).write(
      to: directory.appendingPathComponent(RecordingPackageInfo.fileName),
      options: .atomic
    )
    try RecordingPackage.remuxReadme.write(
      to: directory.appendingPathComponent(RecordingPackage.readmeFileName),
      atomically: true,
      encoding: .utf8
    )

    mainTrack = try HLSByteRangeTrackRecorder(
      directory: directory,
      mediaFileName: "output-video.mp4"
    )

    var audioTracks: [String: HLSByteRangeTrackRecorder] = [:]
    for audioTrack in configuration.audioTracks {
      audioTracks[audioTrack.id] = try HLSByteRangeTrackRecorder(
        directory: directory,
        mediaFileName: "\(audioTrack.fileNameStem).mp4"
      )
    }
    self.audioTracks = audioTracks

  }

  func setVideoCodecs(_ codecs: String) {
    configurationLock.withLock {
      configuration.videoCodecs = codecs
    }
  }

  func finish(beforeFinalizedMarker: () throws -> Void = {}) throws {
    mainTrack.finish()
    for recorder in audioTracks.values {
      recorder.finish()
    }
    try mainTrack.validateForFinalization()
    let finalConfiguration: HLSByteRangeRecordingPackageConfiguration =
      configurationLock.withLock { self.configuration }
    let audioSnapshots = try finalConfiguration.audioTracks.map { track in
      guard let recorder = audioTracks[track.id] else {
        throw HLSByteRangeRecordingPackageError.missingTrack(track.id)
      }
      try recorder.validateForFinalization()
      return (track, recorder.snapshot())
    }
    try MPEGDASHManifestWriter.write(
      configuration: finalConfiguration,
      video: mainTrack.snapshot(),
      audio: audioSnapshots
    )
    try beforeFinalizedMarker()
    try Data().write(to: finalizedMarkerURL, options: .atomic)
  }
}

struct MP4ByteRange: Equatable, Sendable {
  var offset: Int
  var length: Int

  var dashRange: String { "\(offset)-\(offset + length - 1)" }
}

struct MP4MediaSegmentReference: Equatable, Sendable {
  var range: MP4ByteRange
  var durationSeconds: Double
  var earliestPresentationTimeSeconds: Double
}

struct MP4TrackSnapshot: Equatable, Sendable {
  var mediaFileName: String
  var initialization: MP4ByteRange?
  var segments: [MP4MediaSegmentReference]
}

final class HLSByteRangeTrackRecorder: @unchecked Sendable {
  private let mediaURL: URL
  private let mediaFileName: String
  private let lock = NSLock()

  private var byteOffset = 0
  private var initialization: MP4ByteRange?
  private var segments: [MP4MediaSegmentReference] = []
  private var presentationStartSeconds: Double?
  private var isFinished = false
  private var storedFailure: (any Error)?

  init(
    directory: URL,
    mediaFileName: String
  ) throws {
    self.mediaFileName = mediaFileName
    mediaURL = directory.appendingPathComponent(mediaFileName)

    try FileManager.default.createDirectory(
      at: mediaURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: mediaURL.path, contents: nil)
  }

  func write(_ segment: SegmentedMP4Segment) throws {
    try lock.withLock {
      guard !isFinished else { return }

      let offset = byteOffset
      do {
        try append(segment.data)
      } catch {
        if storedFailure == nil { storedFailure = error }
        throw error
      }
      byteOffset += segment.data.count

      switch segment.kind {
      case .initialization:
        initialization = MP4ByteRange(offset: offset, length: segment.data.count)

      case .media:
        let previousEnd =
          segments.last.map {
            $0.earliestPresentationTimeSeconds + $0.durationSeconds
          } ?? 0
        segments.append(
          MP4MediaSegmentReference(
            range: MP4ByteRange(offset: offset, length: segment.data.count),
            durationSeconds: max(segment.durationSeconds ?? 0.001, 0.001),
            earliestPresentationTimeSeconds: segment.earliestPresentationTimeSeconds
              ?? previousEnd
          )
        )
      }
    }
  }

  func finish() {
    lock.withLock {
      isFinished = true
    }
  }

  func markFailed(_ error: any Error) {
    lock.withLock {
      if storedFailure == nil { storedFailure = error }
    }
  }

  func validateForFinalization() throws {
    try lock.withLock {
      if let storedFailure { throw storedFailure }
      guard initialization != nil, !segments.isEmpty else {
        throw HLSByteRangeRecordingPackageError.incompleteTrack(mediaFileName)
      }
    }
  }

  func notePresentationStart(_ presentationTime: CMTime) {
    guard presentationTime.isNumeric, presentationTime.seconds.isFinite else { return }
    lock.withLock {
      if presentationStartSeconds == nil {
        presentationStartSeconds = presentationTime.seconds
      }
    }
  }

  func snapshot() -> MP4TrackSnapshot {
    lock.withLock {
      let writerStart = segments.first?.earliestPresentationTimeSeconds ?? 0
      let timelineOffset = (presentationStartSeconds ?? writerStart) - writerStart
      return MP4TrackSnapshot(
        mediaFileName: mediaFileName,
        initialization: initialization,
        segments: segments.map { segment in
          var adjusted = segment
          adjusted.earliestPresentationTimeSeconds += timelineOffset
          return adjusted
        }
      )
    }
  }

  private func append(_ data: Data) throws {
    let handle = try FileHandle(forWritingTo: mediaURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }
}

private enum MPEGDASHManifestWriter {
  private static let timescale: Int64 = 1_000_000

  static func write(
    configuration: HLSByteRangeRecordingPackageConfiguration,
    video: MP4TrackSnapshot,
    audio: [(HLSByteRangeRecordingAudioTrack, MP4TrackSnapshot)]
  ) throws {
    let snapshots = [video] + audio.map { $0.1 }
    let presentationOrigin =
      snapshots.compactMap {
        $0.segments.first?.earliestPresentationTimeSeconds
      }.min() ?? 0
    let presentationDuration =
      snapshots.compactMap { snapshot in
        snapshot.segments.last.map {
          $0.earliestPresentationTimeSeconds + $0.durationSeconds - presentationOrigin
        }
      }.max().map { max($0, 0.001) } ?? 0.001

    var lines = [
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
      "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" profiles=\"urn:mpeg:dash:profile:isoff-live:2011\" type=\"static\" minBufferTime=\"PT1S\" mediaPresentationDuration=\"\(duration(presentationDuration))\">",
      "  <Period id=\"recording\" start=\"PT0S\">",
      "    <AdaptationSet id=\"0\" contentType=\"video\" mimeType=\"video/mp4\" segmentAlignment=\"true\" startWithSAP=\"1\">",
      "      <Representation id=\"output-video\" bandwidth=\"\(max(configuration.bandwidth, 1))\" codecs=\"\(xml(configuration.videoCodecs))\">",
    ]
    appendSegmentList(
      snapshot: video,
      presentationOrigin: presentationOrigin,
      indentation: "        ",
      to: &lines
    )
    lines += [
      "      </Representation>",
      "    </AdaptationSet>",
    ]

    for (index, entry) in audio.enumerated() {
      let (track, snapshot) = entry
      lines += [
        "    <AdaptationSet id=\"\(index + 1)\" contentType=\"audio\" mimeType=\"audio/mp4\" segmentAlignment=\"true\" startWithSAP=\"1\">",
        "      <Label>\(xml(track.displayName))</Label>",
        "      <Representation id=\"\(xml(track.id))\" bandwidth=\"128000\" codecs=\"\(xml(configuration.audioCodecs))\">",
      ]
      appendSegmentList(
        snapshot: snapshot,
        presentationOrigin: presentationOrigin,
        indentation: "        ",
        to: &lines
      )
      lines += [
        "      </Representation>",
        "    </AdaptationSet>",
      ]
    }

    lines += [
      "  </Period>",
      "</MPD>",
      "",
    ]
    try lines.joined(separator: "\n").write(
      to: configuration.directory.appendingPathComponent(RecordingPackage.manifestFileName),
      atomically: true,
      encoding: .utf8
    )
  }

  private static func appendSegmentList(
    snapshot: MP4TrackSnapshot,
    presentationOrigin: Double,
    indentation: String,
    to lines: inout [String]
  ) {
    let sourceURL = xml(uriPath(snapshot.mediaFileName))
    // SegmentTimeline uses the same media timeline as the fragments' tfdt values.
    // presentationTimeOffset maps the shared native origin to Period time zero while
    // preserving the relative start offset between independently written tracks.
    lines.append(
      "\(indentation)<SegmentList timescale=\"\(timescale)\" presentationTimeOffset=\"\(ticks(presentationOrigin))\">"
    )
    if let initialization = snapshot.initialization {
      lines.append(
        "\(indentation)  <Initialization sourceURL=\"\(sourceURL)\" range=\"\(initialization.dashRange)\"/>"
      )
    }
    lines.append("\(indentation)  <SegmentTimeline>")
    for segment in snapshot.segments {
      lines.append(
        "\(indentation)    <S t=\"\(ticks(segment.earliestPresentationTimeSeconds))\" d=\"\(max(ticks(segment.durationSeconds), 1))\"/>"
      )
    }
    lines.append("\(indentation)  </SegmentTimeline>")
    for segment in snapshot.segments {
      lines.append(
        "\(indentation)  <SegmentURL media=\"\(sourceURL)\" mediaRange=\"\(segment.range.dashRange)\"/>"
      )
    }
    lines.append("\(indentation)</SegmentList>")
  }

  private static func ticks(_ seconds: Double) -> Int64 {
    Int64((seconds * Double(timescale)).rounded())
  }

  private static func duration(_ seconds: Double) -> String {
    String(format: "PT%.6fS", seconds)
  }

  private static func uriPath(_ path: String) -> String {
    path.replacingOccurrences(of: "%", with: "%25")
  }

  private static func xml(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}

final class AudioSideStreamRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private let targetSegmentDurationSeconds: Int
  private let onInitializationSegment: @Sendable (Data) -> Void
  private let segmentPipeline: AudioSideStreamSegmentPipeline
  private let timelineNormalizer: RecordingTimelineNormalizer?
  private let timelineTrackID: String
  private var trackRecorder: HLSByteRangeTrackRecorder
  private var writer: PCMAudioSegmentedMP4Writer?
  private var isFinishing = false

  init(
    trackRecorder: HLSByteRangeTrackRecorder,
    targetSegmentDurationSeconds: Int,
    timelineNormalizer: RecordingTimelineNormalizer? = nil,
    timelineTrackID: String = "audio",
    onInitializationSegment: @escaping @Sendable (Data) -> Void = { _ in }
  ) throws {
    self.trackRecorder = trackRecorder
    self.targetSegmentDurationSeconds = targetSegmentDurationSeconds
    self.timelineNormalizer = timelineNormalizer
    self.timelineTrackID = timelineTrackID
    self.onInitializationSegment = onInitializationSegment
    segmentPipeline = AudioSideStreamSegmentPipeline()
    segmentPipeline.start { [weak self] segment in
      try self?.write(segment)
    }
  }

  func append(_ sampleBuffer: CMSampleBuffer) {
    guard let timelineNormalizer else {
      appendNormalized(sampleBuffer)
      return
    }
    timelineNormalizer.submit(sampleBuffer, trackID: timelineTrackID) { [weak self] normalized in
      self?.appendNormalized(normalized)
    }
  }

  private func appendNormalized(_ sampleBuffer: CMSampleBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard !isFinishing else { return }

    trackRecorder.notePresentationStart(sampleBuffer.presentationTimeStamp)

    do {
      if writer == nil {
        guard let formatDescription = sampleBuffer.formatDescription else {
          hlsByteRangeRecordingLogger.error(
            "Audio side stream sample has no format description"
          )
          return
        }
        writer = try PCMAudioSegmentedMP4Writer(
          formatDescription: formatDescription,
          targetSegmentDurationSeconds: targetSegmentDurationSeconds,
          onSegment: { [weak self] segment in
            self?.segmentPipeline.yield(segment)
          }
        )
      }
      writer?.append(sampleBuffer)
    } catch {
      trackRecorder.markFailed(error)
      let nsError = error as NSError
      hlsByteRangeRecordingLogger.error(
        "Audio side stream append failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)"
      )
      writer = nil
    }
  }

  func finish(completionHandler: @escaping @Sendable () -> Void = {}) {
    let resources = lock.withLock {
      () -> (
        writer: PCMAudioSegmentedMP4Writer?,
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
      if case .failure(let error) = result {
        resources.trackRecorder.markFailed(error)
        let nsError = error as NSError
        hlsByteRangeRecordingLogger.error(
          "Audio side stream finish failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)"
        )
      }
      finishPipeline()
    }
  }

  private func write(_ segment: SegmentedMP4Segment) throws {
    let trackRecorder = lock.withLock { () -> HLSByteRangeTrackRecorder in
      return self.trackRecorder
    }
    if case .initialization = segment.kind {
      onInitializationSegment(segment.data)
    }
    try trackRecorder.write(segment)
  }

}

enum HLSByteRangeRecordingPackageError: Error, LocalizedError {
  case missingTrack(String)
  case incompleteTrack(String)

  var errorDescription: String? {
    switch self {
    case .missingTrack(let identifier):
      "Recording package is missing track \(identifier)."
    case .incompleteTrack(let mediaFileName):
      "Recording track did not produce initialization and media segments: \(mediaFileName)"
    }
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
          hlsByteRangeRecordingLogger.error(
            "Audio side stream segment write failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)"
          )
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
