// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXCapture
import LDTXMP4
import LDTXRecording
import OSLog

private let sessionRecordServiceLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "record-service"
)

public struct SessionRecordAudioTrack: Sendable, Equatable {
  public var key: String
  public var deviceID: String
  public var trackID: String
  public var displayName: String
  public var fileNameStem: String

  public init(
    key: String,
    deviceID: String,
    trackID: String,
    displayName: String,
    fileNameStem: String
  ) {
    self.key = key
    self.deviceID = deviceID
    self.trackID = trackID
    self.displayName = displayName
    self.fileNameStem = fileNameStem
  }

  public static func make(
    deviceIDsByInputKey: [String: String],
    deviceNamesByInputKey: [String: String]
  ) -> [Self] {
    var usedTrackIDs: Set<String> = ["main", "main-mix"]
    var usedFileNameStems: Set<String> = []
    return
      deviceIDsByInputKey
      .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
      .map { key, deviceID in
        let baseTrackID = sanitizedTrackID(key)
        var trackID = baseTrackID
        var trackSuffix = 2
        while usedTrackIDs.contains(trackID) {
          trackID = "\(baseTrackID)-\(trackSuffix)"
          trackSuffix += 1
        }
        usedTrackIDs.insert(trackID)
        let displayName = deviceNamesByInputKey[key] ?? key
        let encodedName = percentEncodedFileName(displayName)
        var fileNameStem = "InputDevices/\(encodedName)"
        var fileSuffix = 2
        while usedFileNameStems.contains(fileNameStem) {
          fileNameStem = "InputDevices/\(encodedName)~\(fileSuffix)"
          fileSuffix += 1
        }
        usedFileNameStems.insert(fileNameStem)
        return Self(
          key: key,
          deviceID: deviceID,
          trackID: trackID,
          displayName: displayName,
          fileNameStem: fileNameStem)
      }
  }

  private static func sanitizedTrackID(_ value: String) -> String {
    let scalars = value.lowercased().unicodeScalars.map { scalar -> UnicodeScalar in
      CharacterSet.alphanumerics.contains(scalar) ? scalar : UnicodeScalar(0x2D)!
    }
    let result = String(String.UnicodeScalarView(scalars))
      .split(separator: "-", omittingEmptySubsequences: true)
      .joined(separator: "-")
    return result.isEmpty ? "audio" : result
  }

  private static func percentEncodedFileName(_ value: String) -> String {
    let encoded = value.utf8.map { byte -> String in
      switch byte {
      case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
        String(UnicodeScalar(byte))
      default: String(format: "%%%02X", byte)
      }
    }.joined()
    return encoded.isEmpty ? "Audio" : encoded
  }
}

public enum SessionRecordFinalizationResult: @unchecked Sendable {
  case finalized
  case preservedIncomplete
  case failed(any Error)
}

/// Writes one Output Session record to one `.ldtxrecord` package.
///
/// Capture sessions and subscriptions are owned outside this service. The
/// service is deliberately cheap to replace at a Session Record Cut boundary.
public final class SessionRecordService: @unchecked Sendable {
  private struct DiagnosticsState {
    var isPrepared = false
    var isClosed = false
    var eventLog: RecordingDiagnosticsEventLog?
    var pendingEvents: [RecordingDiagnosticsEventKind] = []
  }

  private enum State {
    case idle
    case starting
    case writing
    case stopping
    case stopped
  }

  public let packageDirectory: URL

  private var package: HLSByteRangeRecordingPackage?
  private var timelineNormalizer: RecordingTimelineNormalizer?
  private let inputRecordingWindow = SessionRecordInputWindow()
  private let mainAudioRecordingWindow = SessionRecordInputWindow()
  private let pendingAudioWindow = SessionRecordPendingAudioWindow()
  private var recordingPipeline: SessionRecordingPipeline?
  private let recordID: String
  private let writerConfiguration: SegmentedMP4WriterConfiguration
  private let audioTracks: [SessionRecordAudioTrack]
  private let targetSegmentDurationSeconds: Int
  private let failureHandler: @MainActor (Error) -> Void
  private let diagnosticsContext: RecordingDiagnosticsContext?
  private let mediaQueue = DispatchQueue(label: "tokyo.kaito.ldtx.record-service-media")
  private let stateLock = NSLock()
  private let diagnosticsLock = NSLock()
  private var diagnosticsState = DiagnosticsState()
  private var sideRecordersByTrackID: [String: AudioSideStreamRecorder] = [:]
  private var state: State = .idle
  private var discardsPackageWhenStopped = false
  private var preservesIncompletePackageWhenStopped = false
  private var recordsOutputStoppedWhenStopCompletes = false
  private var stopHandlers: [@MainActor @Sendable (SessionRecordFinalizationResult) -> Void] = []
  private var videoCodecString: String?
  private var recordingClockOrigin: ContinuousClock.Instant?
  private var resourcePreparationFailed = false
  public private(set) var hasAcceptedFirstVideo = false
  private var finalizationResult: SessionRecordFinalizationResult?

  public init(
    baseDirectory: URL,
    recordID: String,
    writerConfiguration: SegmentedMP4WriterConfiguration,
    audioTracks: [SessionRecordAudioTrack],
    diagnosticsContext: RecordingDiagnosticsContext? = nil,
    failureHandler: @escaping @MainActor (Error) -> Void
  ) throws {
    packageDirectory =
      baseDirectory
      .appendingPathComponent(recordID, isDirectory: true)
      .appendingPathExtension(RecordingPackage.pathExtension)
    guard !FileManager.default.fileExists(atPath: packageDirectory.path) else {
      throw SessionRecordServiceError.recordingPackageAlreadyExists(packageDirectory)
    }
    self.audioTracks = audioTracks
    self.recordID = recordID
    self.writerConfiguration = writerConfiguration
    targetSegmentDurationSeconds = writerConfiguration.targetSegmentDurationSeconds
    self.failureHandler = failureHandler
    self.diagnosticsContext = diagnosticsContext
  }

  public static func makeRecordID(date: Date = Date()) -> String {
    "LDTX\(makeTimestamp(date: date))"
  }

  public static func makeTimestamp(date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    formatter.formatOptions.remove(.withDashSeparatorInDate)
    formatter.formatOptions.remove(.withColonSeparatorInTime)
    formatter.formatOptions.remove(.withTimeZone)
    formatter.timeZone = .current
    return formatter.string(from: date)
  }

  @MainActor public func start(
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    let started = stateLock.withLock { () -> Bool in
      guard state == .idle else { return false }
      state = .writing
      return true
    }
    guard started else {
      completionHandler(.failure(SessionRecordServiceError.alreadyStarted))
      return
    }
    appendDiagnosticsEvent(.recordingStarted)
    completionHandler(.success(()))
  }

  public func appendMainVideo(_ sampleBuffer: CMSampleBuffer) {
    guard isWriting else { return }
    if !hasAcceptedFirstVideo {
      do {
        try acceptFirstVideo(sampleBuffer)
      } catch {
        Task { @MainActor in failureHandler(error) }
      }
      return
    }
    appendCommittedMainVideo(sampleBuffer)
  }

  /// Atomically prepares a new record package and commits its first sync video sample.
  public func acceptFirstVideo(
    _ sampleBuffer: CMSampleBuffer,
    mainAudioFormatDescription: CMAudioFormatDescription? = nil
  ) throws {
    guard isWriting else { throw SessionRecordServiceError.notWriting }
    guard !hasAcceptedFirstVideo else { throw SessionRecordServiceError.firstVideoAlreadyAccepted }
    guard Self.isSyncVideoSample(sampleBuffer) else {
      throw SessionRecordServiceError.firstVideoMustBeSync
    }
    try prepareResourcesIfNeeded()
    try configureVideoCodecIfNeeded(from: sampleBuffer)
    activateRecordingTimelineIfNeeded(at: sampleBuffer.presentationTimeStamp)
    guard let recordingPipeline else { throw SessionRecordServiceError.resourcePreparationFailed }
    try recordingPipeline.appendFirstVideo(
      sampleBuffer,
      mainAudioFormatDescription: mainAudioFormatDescription)
    hasAcceptedFirstVideo = true
    drainPendingAudio(startingAt: sampleBuffer.presentationTimeStamp)
  }

  private func appendCommittedMainVideo(_ sampleBuffer: CMSampleBuffer) {
    if videoCodecString == nil {
      do {
        try configureVideoCodecIfNeeded(from: sampleBuffer)
      } catch {
        Task { @MainActor in failureHandler(error) }
        return
      }
    }
    activateRecordingTimelineIfNeeded(at: sampleBuffer.presentationTimeStamp)
    recordingPipeline?.appendVideo(sampleBuffer)
  }

  public func appendMainAudioMix(_ sampleBuffer: CMSampleBuffer) {
    guard isWriting else { return }
    guard hasAcceptedFirstVideo else {
      bufferPendingAudio(.main(sampleBuffer))
      return
    }
    appendCommittedMainAudioMix(sampleBuffer)
  }

  public func appendInputAudio(_ sampleBuffer: CMSampleBuffer, trackID: String) {
    guard isWriting else { return }
    guard hasAcceptedFirstVideo else {
      bufferPendingAudio(.input(sampleBuffer, trackID: trackID))
      return
    }
    appendCommittedInputAudio(sampleBuffer, trackID: trackID)
  }

  /// Closes the raw-input side of this recording at the Output Session's stop
  /// boundary. Main-stream encoders may still flush already accepted samples.
  public func sealInputAudio() {
    inputRecordingWindow.seal()
  }

  @MainActor public func stop(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void = {
      _ in
    }
  ) {
    stop(recordsOutputStoppedWhenComplete: true, completionHandler: completionHandler)
  }

  /// Finalizes a completed record at a Cut boundary.  A Cut ends only this
  /// record package; the Output Session itself remains active.
  @MainActor public func finishAfterCut(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void = {
      _ in
    }
  ) {
    stop(recordsOutputStoppedWhenComplete: false, completionHandler: completionHandler)
  }

  @MainActor private func stop(
    recordsOutputStoppedWhenComplete: Bool,
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void
  ) {
    if let finalizationResult {
      Task { @MainActor in completionHandler(finalizationResult) }
      return
    }
    stopHandlers.append(completionHandler)
    let previousState = stateLock.withLock { () -> State? in
      guard state != .stopping && state != .stopped else { return nil }
      let previousState = state
      state = .stopping
      return previousState
    }
    guard let previousState else { return }
    recordsOutputStoppedWhenStopCompletes =
      recordsOutputStoppedWhenComplete && previousState == .writing
    discardsPackageWhenStopped = previousState == .idle || previousState == .starting
    inputRecordingWindow.seal()
    mainAudioRecordingWindow.seal()
    pendingAudioWindow.seal()
    guard let timelineNormalizer else {
      mediaQueue.async { [weak self] in self?.finishPackage() }
      return
    }
    let recorders = Array(sideRecordersByTrackID.values)
    mediaQueue.async { [weak self] in
      timelineNormalizer.finish()
      self?.finishSideRecorders(recorders, at: 0)
    }
  }

  /// Stops writers after an abnormal Session termination while deliberately
  /// leaving the recording package incomplete.
  @MainActor public func stopPreservingIncompletePackage(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void = {
      _ in
    }
  ) {
    preservesIncompletePackageWhenStopped = true
    appendDiagnosticsEvent(.abnormalStop)
    stop(completionHandler: completionHandler)
  }

  /// Cancels a replacement service whose first video commit failed.
  @MainActor public func cancelBeforeFirstVideo(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void = {
      _ in
    }
  ) {
    guard !hasAcceptedFirstVideo else {
      stopPreservingIncompletePackage(completionHandler: completionHandler)
      return
    }
    discardsPackageWhenStopped = true
    stop(completionHandler: completionHandler)
  }

  public func recordOutputReconstructionRequested() {
    appendDiagnosticsEvent(.outputReconstructionRequested)
  }

  public func recordOutputStarted() {
    appendDiagnosticsEvent(.outputStarted)
  }

  /// Approximate time on the recording bundle timeline for auxiliary artifacts.
  /// This clock is monotonic but is not synchronized to media presentation timestamps.
  public func recordingTimelineMilliseconds() -> UInt64? {
    guard isWriting, let recordingClockOrigin else { return nil }
    let components = recordingClockOrigin.duration(to: .now).components
    guard components.seconds >= 0 else { return nil }
    let seconds = UInt64(components.seconds)
    let milliseconds = UInt64(max(components.attoseconds, 0) / 1_000_000_000_000_000)
    let (scaledSeconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
    guard !overflow else { return UInt64.max }
    let (result, additionOverflow) = scaledSeconds.addingReportingOverflow(milliseconds)
    return additionOverflow ? UInt64.max : result
  }

  private func prepareResourcesIfNeeded() throws {
    if package != nil { return }
    if resourcePreparationFailed { throw SessionRecordServiceError.resourcePreparationFailed }
    do {
      try reservePackageDirectory()
      let recordingAudioTracks = audioTracks.map {
        HLSByteRangeRecordingAudioTrack(
          id: $0.trackID,
          displayName: $0.displayName,
          fileNameStem: $0.fileNameStem)
      }
      let package = try HLSByteRangeRecordingPackage(
        configuration: HLSByteRangeRecordingPackageConfiguration(
          directory: packageDirectory,
          recordID: recordID,
          targetDurationSeconds: writerConfiguration.targetSegmentDurationSeconds,
          videoCodecs: "",
          audioCodecs: "mp4a.40.2",
          bandwidth: writerConfiguration.videoBitRate + writerConfiguration.audioBitRate,
          includesMainAudioTrack: false,
          audioTracks: recordingAudioTracks),
        directoryIsReserved: true)
      let timelineNormalizer = RecordingTimelineNormalizer()
      let recordingPipeline = try SessionRecordingPipeline(
        package: package,
        targetSegmentDurationSeconds: writerConfiguration.targetSegmentDurationSeconds,
        startNumber: writerConfiguration.startNumber,
        timelineNormalizer: timelineNormalizer,
        failureHandler: { [failureHandler] error in
          Task { @MainActor in
            failureHandler(
              ProgramOutputFlowInterruptionError.recordingWriterFailed(
                error.localizedDescription))
          }
        })
      var sideRecorders: [String: AudioSideStreamRecorder] = [:]
      for track in audioTracks {
        guard let trackRecorder = package.audioTracks[track.trackID] else {
          throw SessionRecordServiceError.missingAudioTrack(track.trackID)
        }
        sideRecorders[track.trackID] = try AudioSideStreamRecorder(
          trackRecorder: trackRecorder,
          targetSegmentDurationSeconds: writerConfiguration.targetSegmentDurationSeconds,
          timelineNormalizer: timelineNormalizer,
          timelineTrackID: track.trackID)
      }
      let diagnosticsEventLog: RecordingDiagnosticsEventLog?
      do {
        diagnosticsEventLog = try diagnosticsContext.map {
          try RecordingDiagnosticsEventLog(packageDirectory: packageDirectory, context: $0)
        }
      } catch {
        diagnosticsEventLog = nil
        sessionRecordServiceLogger.error(
          "Recording diagnostics event log could not be created: \(error.localizedDescription, privacy: .public)"
        )
      }
      self.package = package
      self.timelineNormalizer = timelineNormalizer
      self.recordingPipeline = recordingPipeline
      sideRecordersByTrackID = sideRecorders
      prepareDiagnostics(eventLog: diagnosticsEventLog)
      logPackagePaths()
    } catch {
      resourcePreparationFailed = true
      if let error = error as? SessionRecordServiceError { throw error }
      throw ProgramOutputFlowInterruptionError.recordingWriterFailed(error.localizedDescription)
    }
  }

  private func reservePackageDirectory() throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: packageDirectory.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    do {
      try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: false)
    } catch {
      if fileManager.fileExists(atPath: packageDirectory.path) {
        throw SessionRecordServiceError.recordingPackageAlreadyExists(packageDirectory)
      }
      throw error
    }
  }

  private func configureVideoCodecIfNeeded(from sampleBuffer: CMSampleBuffer) throws {
    guard videoCodecString == nil else { return }
    let codecString = try H264VideoEncoder.codecString(from: sampleBuffer)
    videoCodecString = codecString
    package?.setVideoCodecs(codecString)
  }

  private static func isSyncVideoSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return false }
    let attachments =
      CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
      as? [[CFString: Any]]
    return attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
  }

  private func bufferPendingAudio(_ sample: SessionRecordPendingAudioWindow.Sample) {
    pendingAudioWindow.append(sample)
  }

  private func drainPendingAudio(startingAt presentationTime: CMTime) {
    for sample in pendingAudioWindow.drain(startingAt: presentationTime) {
      switch sample {
      case .main(let sampleBuffer):
        appendCommittedMainAudioMix(sampleBuffer)
      case .input(let sampleBuffer, let trackID):
        appendCommittedInputAudio(sampleBuffer, trackID: trackID)
      }
    }
  }

  private func appendCommittedMainAudioMix(_ sampleBuffer: CMSampleBuffer) {
    guard let recordingPipeline else { return }
    mainAudioRecordingWindow.submit(sampleBuffer) { recordingPipeline.appendAudio($0) }
  }

  private func appendCommittedInputAudio(_ sampleBuffer: CMSampleBuffer, trackID: String) {
    guard let recorder = sideRecordersByTrackID[trackID] else { return }
    inputRecordingWindow.submit(sampleBuffer) { recorder.append($0) }
  }

  private func activateRecordingTimelineIfNeeded(at presentationTime: CMTime) {
    guard let origin = timelineNormalizer?.activate(at: presentationTime) else { return }
    if recordingClockOrigin == nil { recordingClockOrigin = .now }
    inputRecordingWindow.activate(at: origin)
    mainAudioRecordingWindow.activate(at: origin)
  }

  private func finishSideRecorders(_ recorders: [AudioSideStreamRecorder], at index: Int) {
    guard index < recorders.count else {
      guard let recordingPipeline else {
        finishPackage()
        return
      }
      recordingPipeline.finish { [weak self] in
        self?.mediaQueue.async { [weak self] in self?.finishPackage() }
      }
      return
    }
    recorders[index].finish { [weak self] in
      self?.mediaQueue.async { [weak self] in
        self?.finishSideRecorders(recorders, at: index + 1)
      }
    }
  }

  private func finishPackage() {
    if recordsOutputStoppedWhenStopCompletes {
      appendDiagnosticsEvent(.outputStopped)
      recordsOutputStoppedWhenStopCompletes = false
    }
    if discardsPackageWhenStopped {
      closeDiagnostics(normally: false)
      discardCancelledPackage()
      completeStop(.preservedIncomplete)
      return
    }
    if preservesIncompletePackageWhenStopped {
      closeDiagnostics(normally: false)
      completeStop(.preservedIncomplete)
      return
    }
    do {
      guard let package else {
        completeStop(
          .failed(
            ProgramOutputFlowInterruptionError.recordingFinalizationFailed(
              "No video sample was accepted before recording stopped.")))
        return
      }
      try package.finish { [weak self] in
        self?.closeDiagnostics(normally: true)
      }
      completeStop(.finalized)
    } catch {
      closeDiagnostics(normally: false)
      sessionRecordServiceLogger.error(
        "Record package finalization failed: \(error.localizedDescription, privacy: .public)"
      )
      completeStop(
        .failed(
          ProgramOutputFlowInterruptionError.recordingFinalizationFailed(
            error.localizedDescription)))
    }
  }

  private func discardCancelledPackage() {
    do {
      if FileManager.default.fileExists(atPath: packageDirectory.path) {
        try FileManager.default.removeItem(at: packageDirectory)
      }
    } catch {
      sessionRecordServiceLogger.error(
        "Cancelled record package cleanup failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func completeStop(_ result: SessionRecordFinalizationResult) {
    Task { @MainActor [weak self] in self?.completeStopOnMainActor(result) }
  }

  @MainActor private func completeStopOnMainActor(_ result: SessionRecordFinalizationResult) {
    guard finalizationResult == nil else { return }
    finalizationResult = result
    stateLock.withLock { state = .stopped }
    let handlers = stopHandlers
    stopHandlers.removeAll()
    for handler in handlers { handler(result) }
  }

  private var isWriting: Bool { stateLock.withLock { state == .writing } }

  private func appendDiagnosticsEvent(_ kind: RecordingDiagnosticsEventKind) {
    diagnosticsLock.withLock {
      guard !diagnosticsState.isClosed else { return }
      guard diagnosticsState.isPrepared else {
        diagnosticsState.pendingEvents.append(kind)
        return
      }
      appendDiagnosticsEvent(kind, to: diagnosticsState.eventLog)
    }
  }

  private func prepareDiagnostics(eventLog: RecordingDiagnosticsEventLog?) {
    diagnosticsLock.withLock {
      guard !diagnosticsState.isPrepared, !diagnosticsState.isClosed else { return }
      diagnosticsState.isPrepared = true
      diagnosticsState.eventLog = eventLog
      let pendingEvents = diagnosticsState.pendingEvents
      diagnosticsState.pendingEvents = []
      for event in pendingEvents { appendDiagnosticsEvent(event, to: eventLog) }
    }
  }

  private func closeDiagnostics(normally: Bool) {
    diagnosticsLock.withLock {
      guard !diagnosticsState.isClosed else { return }
      diagnosticsState.isClosed = true
      let eventLog = diagnosticsState.eventLog
      diagnosticsState.eventLog = nil
      do {
        if normally { try eventLog?.append(.normalCompletion) }
        try eventLog?.close()
      } catch {
        sessionRecordServiceLogger.error(
          "Recording diagnostics completion event was discarded: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  private func appendDiagnosticsEvent(
    _ kind: RecordingDiagnosticsEventKind,
    to eventLog: RecordingDiagnosticsEventLog?
  ) {
    do {
      try eventLog?.append(kind)
    } catch {
      sessionRecordServiceLogger.error(
        "Recording diagnostics event was discarded kind=\(kind.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func logPackagePaths() {
    sessionRecordServiceLogger.notice(
      "Record package created directory=\(self.packageDirectory.path, privacy: .public) audioTrackCount=\(self.audioTracks.count, privacy: .public)"
    )
  }
}

final class SessionRecordPendingAudioWindow {
  enum Sample {
    case main(CMSampleBuffer)
    case input(CMSampleBuffer, trackID: String)

    var presentationTimeStamp: CMTime {
      switch self {
      case .main(let sampleBuffer), .input(let sampleBuffer, _):
        sampleBuffer.presentationTimeStamp
      }
    }
  }

  private var samples: [Sample] = []
  private var latestPresentationTime: CMTime?
  private var isSealed = false

  func append(_ sample: Sample) {
    guard !isSealed, sample.presentationTimeStamp.isNumeric else { return }
    samples.append(sample)
    if latestPresentationTime.map({
      CMTimeCompare(sample.presentationTimeStamp, $0) > 0
    }) ?? true {
      latestPresentationTime = sample.presentationTimeStamp
    }
    guard let latestPresentationTime else { return }
    let earliest = CMTimeSubtract(
      latestPresentationTime,
      CMTime(seconds: 60, preferredTimescale: 600))
    samples.removeAll {
      CMTimeCompare($0.presentationTimeStamp, earliest) < 0
    }
  }

  func drain(startingAt presentationTime: CMTime) -> [Sample] {
    guard !isSealed else { return [] }
    let accepted = samples.filter {
      CMTimeCompare($0.presentationTimeStamp, presentationTime) >= 0
    }
    samples.removeAll(keepingCapacity: false)
    latestPresentationTime = nil
    return accepted
  }

  func seal() {
    isSealed = true
    samples.removeAll(keepingCapacity: false)
    latestPresentationTime = nil
  }
}

final class SessionRecordInputWindow: @unchecked Sendable {
  private struct PendingSample {
    var sampleBuffer: CMSampleBuffer
    var output: @Sendable (CMSampleBuffer) -> Void
  }

  private let lock = NSLock()
  private var startPresentationTime: CMTime?
  private var latestPendingPresentationTime: CMTime?
  private var isSealed = false
  private var pendingSamples: [PendingSample] = []

  func activate(at presentationTime: CMTime) {
    guard presentationTime.isNumeric else { return }
    lock.lock()
    defer { lock.unlock() }
    guard !isSealed, startPresentationTime == nil else { return }
    startPresentationTime = presentationTime
    let accepted = pendingSamples.filter {
      CMTimeCompare($0.sampleBuffer.presentationTimeStamp, presentationTime) >= 0
    }
    pendingSamples.removeAll(keepingCapacity: false)
    latestPendingPresentationTime = nil
    // Keep the lock while draining so a newly arriving sample cannot overtake
    // an older buffered sample from the same capture callback queue.
    for sample in accepted {
      sample.output(sample.sampleBuffer)
    }
  }

  func submit(
    _ sampleBuffer: CMSampleBuffer,
    output: @escaping @Sendable (CMSampleBuffer) -> Void
  ) {
    let presentationTime = sampleBuffer.presentationTimeStamp
    guard presentationTime.isNumeric else { return }
    lock.lock()
    defer { lock.unlock() }
    guard !isSealed else { return }
    guard let startPresentationTime else {
      pendingSamples.append(PendingSample(sampleBuffer: sampleBuffer, output: output))
      if latestPendingPresentationTime.map({
        CMTimeCompare(presentationTime, $0) > 0
      }) ?? true {
        latestPendingPresentationTime = presentationTime
      }
      trimPendingSamples()
      return
    }
    guard CMTimeCompare(presentationTime, startPresentationTime) >= 0 else { return }
    output(sampleBuffer)
  }

  private func trimPendingSamples() {
    guard let latestPendingPresentationTime else { return }
    let earliest = CMTimeSubtract(
      latestPendingPresentationTime, CMTime(seconds: 60, preferredTimescale: 600))
    pendingSamples.removeAll {
      CMTimeCompare($0.sampleBuffer.presentationTimeStamp, earliest) < 0
    }
  }

  func seal() {
    lock.withLock {
      isSealed = true
      pendingSamples.removeAll(keepingCapacity: false)
      latestPendingPresentationTime = nil
    }
  }
}

public enum SessionRecordServiceError: Error, LocalizedError {
  case alreadyStarted
  case recordingPackageAlreadyExists(URL)
  case missingAudioTrack(String)
  case notWriting
  case firstVideoAlreadyAccepted
  case firstVideoMustBeSync
  case resourcePreparationFailed

  public var errorDescription: String? {
    switch self {
    case .alreadyStarted: "The record service can only be started once."
    case .recordingPackageAlreadyExists(let url):
      "A recording with the same date and time ID already exists: \(url.lastPathComponent)"
    case .missingAudioTrack(let id):
      "The recording package is missing audio track \(id)."
    case .notWriting: "The record service is not accepting media."
    case .firstVideoAlreadyAccepted: "The first video sample was already accepted."
    case .firstVideoMustBeSync: "A Session Record must begin with a sync video sample."
    case .resourcePreparationFailed: "Recording resources could not be prepared."
    }
  }
}
