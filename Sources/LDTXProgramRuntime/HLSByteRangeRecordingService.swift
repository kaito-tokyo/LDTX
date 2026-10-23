// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import LDTXMP4
import LDTXRecordBundleFormat
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
  var landscapeBandwidth: Int
  var portraitBandwidth: Int
  var includesMainAudioTrack: Bool
  var audioTracks: [HLSByteRangeRecordingAudioTrack]
  var formatVersion: Int
  var recordsLandscape: Bool
  var recordsPortrait: Bool

  init(
    directory: URL,
    recordID: String,
    targetDurationSeconds: Int,
    videoCodecs: String,
    audioCodecs: String,
    bandwidth: Int,
    landscapeBandwidth: Int? = nil,
    portraitBandwidth: Int? = nil,
    includesMainAudioTrack: Bool,
    audioTracks: [HLSByteRangeRecordingAudioTrack],
    formatVersion: Int = 2,
    recordsLandscape: Bool = true,
    recordsPortrait: Bool = false
  ) {
    self.directory = directory
    self.recordID = recordID
    self.targetDurationSeconds = targetDurationSeconds
    self.videoCodecs = videoCodecs
    self.audioCodecs = audioCodecs
    self.bandwidth = bandwidth
    self.landscapeBandwidth = landscapeBandwidth ?? bandwidth
    self.portraitBandwidth = portraitBandwidth ?? bandwidth
    self.includesMainAudioTrack = includesMainAudioTrack
    self.audioTracks = audioTracks
    self.formatVersion = formatVersion
    self.recordsLandscape = recordsLandscape
    self.recordsPortrait = recordsPortrait
  }
}

final class HLSByteRangeRecordingPackage: @unchecked Sendable {
  static let fragmentedMainMediaFileName = "main.fragmented.mp4"
  static let landscapeMediaFileName = "landscape.fragmented.mp4"
  static let portraitMediaFileName = "portrait.fragmented.mp4"
  let directory: URL
  let recordID: String
  let mainTrack: HLSByteRangeTrackRecorder
  let canvasTracks: [RecordingCanvas: HLSByteRangeTrackRecorder]
  let audioTracks: [String: HLSByteRangeTrackRecorder]
  private let configurationLock = NSLock()
  private var configuration: HLSByteRangeRecordingPackageConfiguration
  private let finalizedMarkerURL: URL

  init(
    configuration: HLSByteRangeRecordingPackageConfiguration,
    directoryIsReserved: Bool = false
  ) throws {
    directory = configuration.directory
    recordID = configuration.recordID
    self.configuration = configuration
    if !directoryIsReserved {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    finalizedMarkerURL = directory.appendingPathComponent(
      RecordingPackage.finalizedMarkerFileName
    )
    if FileManager.default.fileExists(atPath: finalizedMarkerURL.path) {
      try FileManager.default.removeItem(at: finalizedMarkerURL)
    }
    let infoAudioTracks = configuration.audioTracks.map { track in
      RecordingPackageInfoAudioTrack(
        identifier: track.id,
        name: track.displayName,
        mediaFile: "\(track.fileNameStem).m4a"
      )
    }
    let infoData =
      if configuration.formatVersion == 3 {
        try RecordingPackageInfo.v3Data(
          identifier: configuration.recordID,
          landscapeMediaFile: configuration.recordsLandscape ? Self.landscapeMediaFileName : nil,
          portraitMediaFile: configuration.recordsPortrait ? Self.portraitMediaFileName : nil,
          audioTracks: infoAudioTracks)
      } else {
        try RecordingPackageInfo.data(
          identifier: configuration.recordID,
          mainMediaFile: Self.fragmentedMainMediaFileName,
          audioTracks: infoAudioTracks)
      }
    try infoData.write(
      to: directory.appendingPathComponent(RecordingPackageInfo.fileName),
      options: .atomic
    )
    try RecordingPackage.remuxReadme.write(
      to: directory.appendingPathComponent(RecordingPackage.readmeFileName),
      atomically: true,
      encoding: .utf8
    )

    var canvasTracks: [RecordingCanvas: HLSByteRangeTrackRecorder] = [:]
    if configuration.formatVersion == 3 {
      if configuration.recordsLandscape {
        canvasTracks[.landscape] = try HLSByteRangeTrackRecorder(
          directory: directory, mediaFileName: Self.landscapeMediaFileName)
      }
      if configuration.recordsPortrait {
        canvasTracks[.portrait] = try HLSByteRangeTrackRecorder(
          directory: directory, mediaFileName: Self.portraitMediaFileName)
      }
    } else {
      canvasTracks[.landscape] = try HLSByteRangeTrackRecorder(
        directory: directory, mediaFileName: Self.fragmentedMainMediaFileName)
    }
    guard let primaryTrack = canvasTracks[.landscape] ?? canvasTracks[.portrait] else {
      throw HLSByteRangeRecordingPackageError.missingTrack("canvas")
    }
    self.canvasTracks = canvasTracks
    mainTrack = primaryTrack

    var audioTracks: [String: HLSByteRangeTrackRecorder] = [:]
    for audioTrack in configuration.audioTracks {
      audioTracks[audioTrack.id] = try HLSByteRangeTrackRecorder(
        directory: directory,
        mediaFileName: "\(audioTrack.fileNameStem).m4a"
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
    for recorder in canvasTracks.values { recorder.finish() }
    for recorder in audioTracks.values {
      recorder.finish()
    }
    for recorder in canvasTracks.values { try recorder.validateForFinalization() }
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
      videos: canvasTracks.sorted { $0.key.rawValue < $1.key.rawValue }.map {
        ($0.key, $0.value.snapshot())
      },
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
  var audioPresentationStartNanoseconds: Int64?
}

final class HLSByteRangeTrackRecorder: @unchecked Sendable {
  private let mediaURL: URL
  private let mediaFileName: String
  private let lock = NSLock()

  private var byteOffset = 0
  private var initialization: MP4ByteRange?
  private var segments: [MP4MediaSegmentReference] = []
  private var presentationStartSeconds: Double?
  private var audioPresentationStartNanoseconds: Int64?
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
      if let storedFailure { throw storedFailure }

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
        },
        audioPresentationStartNanoseconds: audioPresentationStartNanoseconds
      )
    }
  }

  func noteAudioPresentationStart(_ time: CMTime) {
    guard time.isNumeric else { return }
    lock.withLock {
      if audioPresentationStartNanoseconds == nil {
        audioPresentationStartNanoseconds =
          CMTimeConvertScale(
            time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero
          ).value
      }
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
  private static let timescale: Int64 = 1_000_000_000

  static func write(
    configuration: HLSByteRangeRecordingPackageConfiguration,
    videos: [(RecordingCanvas, MP4TrackSnapshot)],
    audio: [(HLSByteRangeRecordingAudioTrack, MP4TrackSnapshot)]
  ) throws {
    let snapshots = videos.map { $0.1 } + audio.map { $0.1 }
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
    ]
    for (index, entry) in videos.enumerated() {
      let (canvas, snapshot) = entry
      lines += [
        "    <AdaptationSet id=\"\(index)\" mimeType=\"video/mp4\" segmentAlignment=\"true\" startWithSAP=\"1\">",
        "      <Label>\(canvas.rawValue.capitalized)</Label>",
        "      <ContentComponent id=\"1\" contentType=\"video\"/>",
        "      <ContentComponent id=\"2\" contentType=\"audio\"/>",
        "      <Representation id=\"\(canvas.rawValue)\" bandwidth=\"\(max(canvas == .portrait ? configuration.portraitBandwidth : configuration.landscapeBandwidth, 1))\" codecs=\"\(xml(configuration.videoCodecs)),\(xml(configuration.audioCodecs))\">",
      ]
      if let start = snapshot.audioPresentationStartNanoseconds {
        lines.append(
          "        <SupplementalProperty schemeIdUri=\"\(RecordingDASHTimeline.audioStartScheme)\" value=\"\(start)\"/>"
        )
      }
      appendSegmentList(
        snapshot: snapshot,
        presentationOrigin: presentationOrigin,
        indentation: "        ",
        to: &lines)
      lines += ["      </Representation>", "    </AdaptationSet>"]
    }

    for (index, entry) in audio.enumerated() {
      let (track, snapshot) = entry
      lines += [
        "    <AdaptationSet id=\"\(videos.count + index)\" contentType=\"audio\" mimeType=\"audio/mp4\" segmentAlignment=\"true\" startWithSAP=\"1\">",
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

protocol AudioSideStreamWriting: Sendable {
  func append(_ sampleBuffer: CMSampleBuffer)
  func finish(
    at presentationTime: CMTime?,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void)
}

extension PCMAudioSegmentedMP4Writer: AudioSideStreamWriting {}

struct AudioSideStreamWriterCallbacks: Sendable {
  let onFailure: @Sendable (any Error) -> Void
  let onSegment: @Sendable (SegmentedMP4Segment) -> Void
}

final class AudioSideStreamRecorder: @unchecked Sendable {
  typealias WriterFactory =
    @Sendable (
      CMAudioFormatDescription, Int, AudioSideStreamWriterCallbacks
    ) throws -> any AudioSideStreamWriting

  // State and finish waiters belong to this queue. Failure callbacks never run
  // under a recorder lock, and may safely request a Session stop immediately.
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.AudioSideStreamRecorder")
  private let targetSegmentDurationSeconds: Int
  private let onInitializationSegment: @Sendable (Data) -> Void
  private let segmentPipeline: AudioSideStreamSegmentPipeline
  private let timelineNormalizer: RecordingTimelineNormalizer?
  private let timelineTrackID: String
  private let trackRecorder: HLSByteRangeTrackRecorder
  private let writerFactory: WriterFactory
  private var writer: (any AudioSideStreamWriting)?
  private var receivedSample = false
  private enum State { case accepting, finishingWriter, drainingSegments, finished }
  private var state = State.accepting
  private var finishHandlers: [@Sendable () -> Void] = []

  init(
    trackRecorder: HLSByteRangeTrackRecorder,
    targetSegmentDurationSeconds: Int,
    timelineNormalizer: RecordingTimelineNormalizer? = nil,
    timelineTrackID: String = "audio",
    failureHandler: @escaping @Sendable (any Error) -> Void,
    onInitializationSegment: @escaping @Sendable (Data) -> Void = { _ in },
    writerFactory: @escaping WriterFactory = { format, duration, callbacks in
      try PCMAudioSegmentedMP4Writer(
        formatDescription: format, targetSegmentDurationSeconds: duration,
        onFailure: callbacks.onFailure, onSegment: callbacks.onSegment)
    }
  ) throws {
    self.trackRecorder = trackRecorder
    self.targetSegmentDurationSeconds = targetSegmentDurationSeconds
    self.timelineNormalizer = timelineNormalizer
    self.timelineTrackID = timelineTrackID
    self.onInitializationSegment = onInitializationSegment
    self.writerFactory = writerFactory
    segmentPipeline = AudioSideStreamSegmentPipeline { error in
      trackRecorder.markFailed(error)
      failureHandler(error)
    }
    segmentPipeline.start { [weak self] segment in
      guard let self else { return }
      try self.trackRecorder.write(segment)
      if case .initialization = segment.kind { self.onInitializationSegment(segment.data) }
    }
  }

  func append(_ sampleBuffer: CMSampleBuffer) {
    guard !segmentPipeline.hasFailed else { return }
    guard let timelineNormalizer else {
      appendNormalized(sampleBuffer)
      return
    }
    timelineNormalizer.submit(sampleBuffer, trackID: timelineTrackID) { [weak self] normalized in
      self?.appendNormalized(normalized)
    }
  }

  private func appendNormalized(_ sampleBuffer: CMSampleBuffer) {
    let sample = SendableAudioSideStreamSample(value: sampleBuffer)
    queue.async { [self] in
      guard state == .accepting, !segmentPipeline.hasFailed else { return }
      receivedSample = true
      trackRecorder.notePresentationStart(sample.value.presentationTimeStamp)
      do {
        if writer == nil {
          guard let format = sample.value.formatDescription else {
            throw PCMAudioSegmentedMP4WriterError.invalidConfiguration
          }
          writer = try makeWriter(format: format)
        }
        guard !segmentPipeline.hasFailed else { return }
        writer?.append(sample.value)
      } catch {
        segmentPipeline.fail(error)
      }
    }
  }

  private func makeWriter(format: CMAudioFormatDescription) throws -> any AudioSideStreamWriting {
    let pipeline = segmentPipeline
    return try writerFactory(
      format, targetSegmentDurationSeconds,
      AudioSideStreamWriterCallbacks(
        onFailure: { pipeline.fail($0) }, onSegment: { pipeline.yield($0) }))
  }

  func finish(
    at presentationTime: CMTime? = nil, completionHandler: @escaping @Sendable () -> Void = {}
  ) {
    queue.async { [self] in
      if state == .finished {
        completionHandler()
        return
      }
      finishHandlers.append(completionHandler)
      guard state == .accepting else { return }
      state = .finishingWriter
      if writer == nil, !receivedSample, !segmentPipeline.hasFailed, let presentationTime,
        presentationTime.isNumeric, CMTimeCompare(presentationTime, .zero) > 0
      {
        do {
          guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
          else { throw PCMAudioSegmentedMP4WriterError.invalidConfiguration }
          writer = try makeWriter(format: format.formatDescription)
          trackRecorder.notePresentationStart(.zero)
          hlsByteRangeRecordingLogger.notice(
            "No input samples received; synthesizing recording-only 48 kHz stereo silence")
        } catch {
          segmentPipeline.fail(error)
        }
      }
      guard let writer else {
        finishWriter(.success(()))
        return
      }
      writer.finish(at: presentationTime) { [self] result in
        queue.async { [self] in finishWriter(result) }
      }
    }
  }

  private func finishWriter(_ result: Result<Void, any Error>) {
    guard state == .finishingWriter else { return }
    if case .failure(let error) = result { segmentPipeline.fail(error) }
    state = .drainingSegments
    segmentPipeline.finish { [self] in
      queue.async { [self] in
        guard state == .drainingSegments else { return }
        trackRecorder.finish()
        writer = nil
        state = .finished
        let handlers = finishHandlers
        finishHandlers.removeAll()
        for handler in handlers { handler() }
      }
    }
  }
}

private struct SendableAudioSideStreamSample: @unchecked Sendable {
  let value: CMSampleBuffer
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
  private var storedFailure: (any Error)?
  private var failureReported = false
  private var isFinished = false
  private let failureHandler: @Sendable (any Error) -> Void

  init(failureHandler: @escaping @Sendable (any Error) -> Void) {
    self.failureHandler = failureHandler
  }

  var hasFailed: Bool { lock.withLock { storedFailure != nil } }

  func fail(_ error: any Error) {
    lock.withLock {
      guard storedFailure == nil, !isFinished else { return }
      storedFailure = error
      write = nil
      // Serialize notification with writes and finish barriers. A finish marker
      // already queued before this fault also reports it before its completion.
      queue.async { [self] in reportFailure(finishing: false) }
    }
  }

  private func reportFailure(finishing: Bool) {
    let error = lock.withLock { () -> (any Error)? in
      if finishing {
        isFinished = true
        write = nil
      }
      guard let storedFailure, !failureReported else { return nil }
      failureReported = true
      return storedFailure
    }
    guard let error else { return }
    let nsError = error as NSError
    hlsByteRangeRecordingLogger.error(
      "Audio side stream failed errorDomain=\(nsError.domain, privacy: .private) errorCode=\(nsError.code)"
    )
    failureHandler(error)
  }

  func start(write: @escaping Write) {
    lock.withLock {
      guard self.write == nil, !isFinishing, storedFailure == nil else { return }
      self.write = write
    }
  }

  func yield(_ segment: SegmentedMP4Segment) {
    lock.withLock {
      guard !isFinishing, storedFailure == nil else { return }
      queue.async { [self] in
        let operation = lock.withLock { storedFailure == nil ? write : nil }
        do {
          try operation?(segment)
        } catch {
          fail(error)
        }
      }
    }
  }

  func drain(completionHandler: @escaping @Sendable () -> Void) {
    queue.async { [self] in
      reportFailure(finishing: false)
      completionHandler()
    }
  }

  func perform(_ operation: @escaping @Sendable () throws -> Void) throws {
    try queue.sync(execute: operation)
  }

  func finish(completionHandler: @escaping @Sendable () -> Void = {}) {
    lock.withLock {
      isFinishing = true
      queue.async { [self] in
        reportFailure(finishing: true)
        completionHandler()
      }
    }
  }
}
