// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import LDTXMP4
import LDTXRecording
import LDTXRecordingXPCProtocol
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
  var audioTracks: [HLSByteRangeRecordingAudioTrack]
}

final class HLSByteRangeRecordingPackage: @unchecked Sendable {
  let directory: URL
  let recordID: String
  let mainTrack: HLSByteRangeTrackRecorder
  let audioTracks: [String: HLSByteRangeTrackRecorder]
  private let configuration: HLSByteRangeRecordingPackageConfiguration
  private let sessionCompletionMarkerURL: URL

  init(configuration: HLSByteRangeRecordingPackageConfiguration) throws {
    directory = configuration.directory
    recordID = configuration.recordID
    self.configuration = configuration
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    sessionCompletionMarkerURL = directory.appendingPathComponent(
      RecordingPackage.finalizedMarkerFileName
    )
    if FileManager.default.fileExists(atPath: sessionCompletionMarkerURL.path) {
      try FileManager.default.removeItem(at: sessionCompletionMarkerURL)
    }
    try RecordingPackageInfo.data(
      identifier: configuration.recordID,
      mainMediaFile: "main.mp4",
      audioTracks: configuration.audioTracks.map { track in
        RecordingPackageInfoAudioTrack(
          identifier: track.id,
          name: track.displayName,
          mediaFile: "\(track.fileNameStem).m4a"
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
      mediaFileName: "main.mp4"
    )

    var audioTracks: [String: HLSByteRangeTrackRecorder] = [:]
    for audioTrack in configuration.audioTracks {
      audioTracks[audioTrack.id] = try HLSByteRangeTrackRecorder(
        directory: directory,
        mediaFileName: "\(audioTrack.fileNameStem).m4a"
      )
    }
    self.audioTracks = audioTracks

  }

  /// Creates the writer ledger for a recovered Main Program generation.
  /// Generation one is always `main.mp4`; recovery files use `main~N.mp4`.
  func makeMainGenerationTrack(generation: Int) throws -> HLSByteRangeTrackRecorder {
    precondition(generation > 1)
    return try HLSByteRangeTrackRecorder(
      directory: directory,
      mediaFileName: RecordingTrackID.mainProgram.mediaFileName(generation: generation)
    )
  }

  /// Creates the ledger for a recovered input-device audio generation. The
  /// primary file remains in `Info.plist`; later generations are discovered
  /// from their DASH Periods when the package is opened.
  func makeInputAudioGenerationTrack(
    _ track: HLSByteRangeRecordingAudioTrack,
    generation: Int
  ) throws -> HLSByteRangeTrackRecorder {
    precondition(generation > 1)
    return try HLSByteRangeTrackRecorder(
      directory: directory,
      mediaFileName: RecordingTrackID.inputDeviceAudio(track.id).mediaFileName(
        generation: generation,
        inputDeviceFileNameStem: track.fileNameStem
      )
    )
  }

  /// Completes package bookkeeping and writes the session-completion marker.
  ///
  /// The marker deliberately says nothing about media completeness. Failed or missing tracks are
  /// represented by the durable snapshots that are available in the manifest and are diagnosed
  /// separately by `RecordingPackageVerifier`.
  func completeSession(
    additionalPeriods: [HLSByteRangeRecordingPeriod] = [],
    beforeCompletionMarker: () throws -> Void = {}
  ) throws {
    mainTrack.finish()
    for recorder in audioTracks.values {
      recorder.finish()
    }
    let videoSnapshot = mainTrack.durableSnapshot()
    let audioSnapshots: [(HLSByteRangeRecordingAudioTrack, MP4TrackSnapshot)] =
      configuration.audioTracks.compactMap { track in
        guard let recorder = audioTracks[track.id] else {
          return nil
        }
        return recorder.durableSnapshot().map { (track, $0) }
      }
    try MPEGDASHManifestWriter.write(
      configuration: configuration,
      periods: [HLSByteRangeRecordingPeriod(id: "generation-1", main: videoSnapshot, audio: audioSnapshots)] + additionalPeriods
    )
    try beforeCompletionMarker()
    try Data().write(to: sessionCompletionMarkerURL, options: .atomic)
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

/// A continuous set of durable track fragments.  A writer recovery opens a
/// fresh period instead of pretending that the missing interval is playable.
struct HLSByteRangeRecordingPeriod: Equatable, Sendable {
  var id: String
  var main: MP4TrackSnapshot?
  var audio: [(HLSByteRangeRecordingAudioTrack, MP4TrackSnapshot)]

  init(
    id: String,
    main: MP4TrackSnapshot?,
    audio: [(HLSByteRangeRecordingAudioTrack, MP4TrackSnapshot)]
  ) {
    self.id = id
    self.main = main
    self.audio = audio
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.main == rhs.main
      && lhs.audio.elementsEqual(rhs.audio, by: { $0.0.id == $1.0.id && $0.1 == $1.1 })
  }
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

  func makeOutputFileHandle() throws -> FileHandle {
    let handle = try FileHandle(forWritingTo: mediaURL)
    try handle.truncate(atOffset: 0)
    return handle
  }

  func recordExternalFragment(_ event: Ldtx_Recording_Xpc_V1_Event) {
    lock.withLock {
      guard !isFinished, event.byteLength > 0 else { return }
      let range = MP4ByteRange(offset: Int(event.byteOffset), length: Int(event.byteLength))
      switch event.fragmentKind {
      case .initialization:
        initialization = range
        return
      case .media:
        break
      case .unspecified, .UNRECOGNIZED:
        return
      }
      let duration =
        event.durationTimescale == 0
        ? 0.001
        : Double(event.durationValue) / Double(event.durationTimescale)
      let presentation =
        event.presentationTimescale == 0
        ? (segments.last.map { $0.earliestPresentationTimeSeconds + $0.durationSeconds } ?? 0)
        : Double(event.presentationValue) / Double(event.presentationTimescale)
      segments.append(
        MP4MediaSegmentReference(
          range: range,
          durationSeconds: max(duration, 0.001),
          earliestPresentationTimeSeconds: presentation
        ))
    }
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

  func durableSnapshot() -> MP4TrackSnapshot? {
    lock.withLock {
      guard initialization != nil, !segments.isEmpty else { return nil }
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
    periods: [HLSByteRangeRecordingPeriod]
  ) throws {
    let nonemptyPeriods = periods.filter { $0.main != nil || !$0.audio.isEmpty }
    let snapshots = nonemptyPeriods.flatMap { [$0.main].compactMap { $0 } + $0.audio.map(\.1) }
    let presentationOrigin = snapshots.compactMap { $0.segments.first?.earliestPresentationTimeSeconds }.min() ?? 0
    let presentationEnd = snapshots.compactMap { $0.segments.last.map { $0.earliestPresentationTimeSeconds + $0.durationSeconds } }.max() ?? presentationOrigin
    let presentationDuration = max(presentationEnd - presentationOrigin, 0.001)

    var lines = [
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
      "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" profiles=\"urn:mpeg:dash:profile:isoff-live:2011\" type=\"static\" minBufferTime=\"PT1S\" mediaPresentationDuration=\"\(duration(presentationDuration))\">",
    ]
    for (periodIndex, period) in nonemptyPeriods.enumerated() {
      let periodSnapshots = [period.main].compactMap { $0 } + period.audio.map(\.1)
      let periodOrigin = periodSnapshots.compactMap { $0.segments.first?.earliestPresentationTimeSeconds }.min() ?? presentationOrigin
      lines.append("  <Period id=\"\(xml(period.id))\" start=\"\(duration(max(periodOrigin - presentationOrigin, 0)))\">")
      appendPeriod(
        configuration: configuration,
        main: period.main,
        audio: period.audio,
        presentationOrigin: periodOrigin,
        periodIndex: periodIndex,
        to: &lines
      )
      lines.append("  </Period>")
    }
    lines += [
      "</MPD>",
      "",
    ]
    try lines.joined(separator: "\n").write(
      to: configuration.directory.appendingPathComponent(RecordingPackage.manifestFileName),
      atomically: true,
      encoding: .utf8
    )
  }

  private static func appendPeriod(
    configuration: HLSByteRangeRecordingPackageConfiguration,
    main: MP4TrackSnapshot?,
    audio: [(HLSByteRangeRecordingAudioTrack, MP4TrackSnapshot)],
    presentationOrigin: Double,
    periodIndex: Int,
    to lines: inout [String]
  ) {
    if let main {
      lines += [
        "    <AdaptationSet id=\"0\" contentType=\"video\" mimeType=\"video/mp4\" segmentAlignment=\"true\" startWithSAP=\"1\">",
        "      <Representation id=\"main\" bandwidth=\"\(max(configuration.bandwidth, 1))\" codecs=\"\(xml(configuration.videoCodecs)),\(xml(configuration.audioCodecs))\">",
      ]
      appendSegmentList(
        snapshot: main,
        presentationOrigin: presentationOrigin,
        indentation: "        ",
        to: &lines
      )
      lines += [
        "      </Representation>",
        "    </AdaptationSet>",
      ]
    }

    for (index, entry) in audio.enumerated() {
      let (track, snapshot) = entry
      lines += [
        "    <AdaptationSet id=\"\(periodIndex)-\(index + 1)\" contentType=\"audio\" mimeType=\"audio/mp4\" segmentAlignment=\"true\" startWithSAP=\"1\">",
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
  private let segmentDurationSeconds: Int
  private let onInitializationSegment: @Sendable (Data) -> Void
  private let onFailure: @Sendable (Error) -> Void
  private let segmentPipeline: AudioSideStreamSegmentPipeline
  private let timelineNormalizer: RecordingTimelineNormalizer?
  private let timelineTrackID: String
  private var trackRecorder: HLSByteRangeTrackRecorder
  private var writer: PCMAudioSegmentedMP4Writer?
  private var isFinishing = false
  private var hasFailed = false

  init(
    trackRecorder: HLSByteRangeTrackRecorder,
    segmentDurationSeconds: Int,
    timelineNormalizer: RecordingTimelineNormalizer? = nil,
    timelineTrackID: String = "audio",
    onInitializationSegment: @escaping @Sendable (Data) -> Void = { _ in },
    onFailure: @escaping @Sendable (Error) -> Void = { _ in }
  ) throws {
    self.trackRecorder = trackRecorder
    self.segmentDurationSeconds = segmentDurationSeconds
    self.timelineNormalizer = timelineNormalizer
    self.timelineTrackID = timelineTrackID
    self.onInitializationSegment = onInitializationSegment
    self.onFailure = onFailure
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
    guard !isFinishing, !hasFailed else {
      lock.unlock()
      return
    }

    trackRecorder.notePresentationStart(sampleBuffer.presentationTimeStamp)

    do {
      if writer == nil {
        guard let formatDescription = sampleBuffer.formatDescription else {
          hlsByteRangeRecordingLogger.error(
            "Audio side stream sample has no format description"
          )
          lock.unlock()
          return
        }
        writer = try PCMAudioSegmentedMP4Writer(
          formatDescription: formatDescription,
          segmentDurationSeconds: segmentDurationSeconds,
          onFailure: { [weak self] error in self?.reportFailure(error) },
          onSegment: { [weak self] segment in
            guard let self, !self.segmentPipeline.yield(segment) else { return }
            self.reportFailure(AudioSideStreamSegmentPipelineError.pendingCapacityExceeded)
          }
        )
      }
      writer?.append(sampleBuffer)
    } catch {
      hasFailed = true
      trackRecorder.markFailed(error)
      writer = nil
      lock.unlock()
      let nsError = error as NSError
      hlsByteRangeRecordingLogger.error(
        "Audio side stream append failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)"
      )
      onFailure(error)
      return
    }
    lock.unlock()
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
        self.reportFailure(error)
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
    do {
      try trackRecorder.write(segment)
    } catch {
      reportFailure(error)
      throw error
    }
  }

  private func reportFailure(_ error: Error) {
    let shouldReport = lock.withLock { () -> Bool in
      guard !hasFailed else { return false }
      hasFailed = true
      trackRecorder.markFailed(error)
      return true
    }
    if shouldReport { onFailure(error) }
  }

}

enum HLSByteRangeRecordingPackageError: Error, LocalizedError {
  case missingTrack(String)

  var errorDescription: String? {
    switch self {
    case .missingTrack(let identifier):
      "Recording package is missing track \(identifier)."
    }
  }
}

final class AudioSideStreamSegmentPipeline: @unchecked Sendable {
  typealias Write = @Sendable (SegmentedMP4Segment) throws -> Void

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.AudioSideStreamSegmentPipeline")
  private let maximumPendingSegments: Int
  private var write: Write?
  private var isFinishing = false
  private var pendingSegments = 0

  init(maximumPendingSegments: Int = 16) {
    precondition(maximumPendingSegments > 0)
    self.maximumPendingSegments = maximumPendingSegments
  }

  func start(write: @escaping Write) {
    lock.withLock {
      guard self.write == nil, !isFinishing else { return }
      self.write = write
    }
  }

  @discardableResult
  func yield(_ segment: SegmentedMP4Segment) -> Bool {
    let shouldQueue = lock.withLock { () -> Bool in
      guard !isFinishing, pendingSegments < maximumPendingSegments else { return false }
      pendingSegments += 1
      return true
    }
    guard shouldQueue else { return false }
    queue.async { [self] in
      defer { lock.withLock { pendingSegments -= 1 } }
      do {
        try write?(segment)
      } catch {
        let nsError = error as NSError
        hlsByteRangeRecordingLogger.error(
          "Audio side stream segment write failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)"
        )
      }
    }
    return true
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

private enum AudioSideStreamSegmentPipelineError: Error, LocalizedError {
  case pendingCapacityExceeded

  var errorDescription: String? {
    "The Input Device audio segment queue exceeded its bounded capacity."
  }
}
