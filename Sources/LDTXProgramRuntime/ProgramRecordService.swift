// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXCapture
import LDTXMP4
import LDTXRecording
import OSLog

private let programRecordServiceLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "record-service"
)

public struct ProgramRecordAudioTrack: Sendable, Equatable {
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
    var usedTrackIDs: Set<String> = []
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

/// Writes one `.ldtxrecord` package. It consumes the Output Session's main
/// video and main audio mix, and owns independent capture subscriptions for
/// the un-mixed input-device audio tracks.
@MainActor
public final class ProgramRecordService {
  private enum State {
    case idle
    case starting
    case writing
    case stopping
    case stopped
  }

  public let packageDirectory: URL

  private let package: HLSByteRangeRecordingPackage
  private let timelineNormalizer: RecordingTimelineNormalizer
  private let inputRecordingWindow = ProgramRecordInputRecordingWindow()
  private let recordingPipeline: SeparatedProgramRecordingPipeline
  private let audioTracks: [ProgramRecordAudioTrack]
  private let segmentDurationSeconds: Int
  private let failureHandler: @MainActor (Error) -> Void
  private let makeCaptureService: @Sendable () -> any ProgramAudioCaptureStreaming
  private let diagnosticsEventLog: RecordingDiagnosticsEventLog?
  private var captureServices: [any ProgramAudioCaptureStreaming] = []
  private var sideRecorders: [AudioSideStreamRecorder] = []
  private var pendingCaptureService: (any ProgramAudioCaptureStreaming)?
  private var pendingSideRecorder: AudioSideStreamRecorder?
  private let pendingCaptureStartGroup = DispatchGroup()
  private var state: State = .idle
  private var discardsPackageWhenStopped = false
  private var preservesIncompletePackageWhenStopped = false
  private var recordsOutputStoppedWhenStopCompletes = false
  private var stopHandlers: [@MainActor @Sendable () -> Void] = []

  public convenience init(
    baseDirectory: URL,
    recordID: String,
    writerConfiguration: SegmentedMP4WriterConfiguration,
    audioTracks: [ProgramRecordAudioTrack],
    diagnosticsContext: RecordingDiagnosticsContext? = nil,
    failureHandler: @escaping @MainActor (Error) -> Void
  ) throws {
    try self.init(
      baseDirectory: baseDirectory,
      recordID: recordID,
      writerConfiguration: writerConfiguration,
      audioTracks: audioTracks,
      diagnosticsContext: diagnosticsContext,
      failureHandler: failureHandler,
      makeCaptureService: { CameraCaptureService() })
  }

  init(
    baseDirectory: URL,
    recordID: String,
    writerConfiguration: SegmentedMP4WriterConfiguration,
    audioTracks: [ProgramRecordAudioTrack],
    diagnosticsContext: RecordingDiagnosticsContext? = nil,
    failureHandler: @escaping @MainActor (Error) -> Void,
    makeCaptureService: @escaping @Sendable () -> any ProgramAudioCaptureStreaming
  ) throws {
    packageDirectory =
      baseDirectory
      .appendingPathComponent(recordID, isDirectory: true)
      .appendingPathExtension(RecordingPackage.pathExtension)
    guard !FileManager.default.fileExists(atPath: packageDirectory.path) else {
      throw ProgramRecordServiceError.recordingPackageAlreadyExists(packageDirectory)
    }
    self.audioTracks = audioTracks
    segmentDurationSeconds = writerConfiguration.segmentDurationSeconds
    self.failureHandler = failureHandler
    self.makeCaptureService = makeCaptureService

    let recordingAudioTracks =
      [
        HLSByteRangeRecordingAudioTrack(
          id: SeparatedProgramRecordingPipeline.mainAudioTrackID,
          displayName: "Main Mix",
          fileNameStem: "output-audio"
        )
      ]
      + audioTracks.map {
        HLSByteRangeRecordingAudioTrack(
          id: $0.trackID,
          displayName: $0.displayName,
          fileNameStem: $0.fileNameStem
        )
      }
    package = try HLSByteRangeRecordingPackage(
      configuration: HLSByteRangeRecordingPackageConfiguration(
        directory: packageDirectory,
        recordID: recordID,
        targetDurationSeconds: writerConfiguration.segmentDurationSeconds,
        videoCodecs: "avc1.64002a",
        audioCodecs: "mp4a.40.2",
        bandwidth: writerConfiguration.videoBitRate + writerConfiguration.audioBitRate,
        includesMainAudioTrack: false,
        audioTracks: recordingAudioTracks
      ))
    timelineNormalizer = RecordingTimelineNormalizer()
    recordingPipeline = try SeparatedProgramRecordingPipeline(
      package: package,
      segmentDurationSeconds: writerConfiguration.segmentDurationSeconds,
      startNumber: writerConfiguration.startNumber,
      timelineNormalizer: timelineNormalizer,
      failureHandler: { error in
        Task { @MainActor in
          failureHandler(
            ProgramOutputFlowInterruptionError.recordingWriterFailed(
              error.localizedDescription))
        }
      })
    let diagnosticsPackageDirectory = packageDirectory
    do {
      diagnosticsEventLog = try diagnosticsContext.map {
        try RecordingDiagnosticsEventLog(packageDirectory: diagnosticsPackageDirectory, context: $0)
      }
    } catch {
      diagnosticsEventLog = nil
      programRecordServiceLogger.error(
        "Recording diagnostics event log could not be created: \(error.localizedDescription, privacy: .public)"
      )
    }
    logPackagePaths()
  }

  nonisolated public static func makeRecordID(date: Date = Date()) -> String {
    "LDTX\(makeTimestamp(date: date))"
  }

  nonisolated public static func makeTimestamp(date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    formatter.formatOptions.remove(.withDashSeparatorInDate)
    formatter.formatOptions.remove(.withColonSeparatorInTime)
    formatter.formatOptions.remove(.withTimeZone)
    formatter.timeZone = .current
    return formatter.string(from: date)
  }

  public func start(
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard state == .idle else {
      completionHandler(.failure(ProgramRecordServiceError.alreadyStarted))
      return
    }
    state = .starting
    startAudioTrack(at: 0, completionHandler: completionHandler)
  }

  public func appendMainVideo(_ sampleBuffer: CMSampleBuffer) {
    guard state == .writing else { return }
    activateRecordingTimelineIfNeeded(at: sampleBuffer.presentationTimeStamp)
    recordingPipeline.appendVideo(sampleBuffer)
  }

  public func appendMainAudioMix(_ sampleBuffer: CMSampleBuffer) {
    guard state == .writing else { return }
    activateRecordingTimelineIfNeeded(at: sampleBuffer.presentationTimeStamp)
    recordingPipeline.appendAudio(sampleBuffer)
  }

  /// Closes the raw-input side of this recording at the Output Session's stop
  /// boundary. Main-stream encoders may still flush already accepted samples.
  public nonisolated func sealInputAudio() {
    inputRecordingWindow.seal()
  }

  public func stop(
    completionHandler: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    if state == .stopped {
      completionHandler()
      return
    }
    stopHandlers.append(completionHandler)
    guard state != .stopping else { return }
    recordsOutputStoppedWhenStopCompletes = state == .writing
    discardsPackageWhenStopped = state == .idle || state == .starting
    state = .stopping
    inputRecordingWindow.seal()
    stopPendingCapture { [weak self] in
      guard let self else { return }
      if let recorder = self.pendingSideRecorder {
        self.pendingSideRecorder = nil
        self.sideRecorders.append(recorder)
      }
      self.stopCaptures(at: 0) { [weak self] in
        guard let self else { return }
        // No capture callback may submit another timestamp after the shared
        // recording timeline has been sealed.
        self.timelineNormalizer.finish()
        self.finishSideRecorders(at: 0)
      }
    }
  }

  /// Stops writers after an abnormal Session termination while deliberately
  /// leaving the recording package incomplete.
  public func stopPreservingIncompletePackage(
    completionHandler: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    preservesIncompletePackageWhenStopped = true
    appendDiagnosticsEvent(.abnormalStop)
    stop(completionHandler: completionHandler)
  }

  public func recordOutputReconstructionRequested() {
    appendDiagnosticsEvent(.outputReconstructionRequested)
  }

  public func recordOutputStarted() {
    appendDiagnosticsEvent(.outputStarted)
  }

  private func startAudioTrack(
    at index: Int,
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard state == .starting else {
      completionHandler(.failure(CancellationError()))
      return
    }
    guard index < audioTracks.count else {
      state = .writing
      appendDiagnosticsEvent(.recordingStarted)
      completionHandler(.success(()))
      return
    }
    let plan = audioTracks[index]
    guard let trackRecorder = package.audioTracks[plan.trackID] else {
      failStart(
        ProgramOutputFlowInterruptionError.recordingAudioTrackUnavailable(plan.displayName),
        displayName: plan.displayName,
        completionHandler: completionHandler)
      return
    }
    do {
      let recorder = try AudioSideStreamRecorder(
        trackRecorder: trackRecorder,
        segmentDurationSeconds: segmentDurationSeconds,
        timelineNormalizer: timelineNormalizer,
        timelineTrackID: plan.trackID
      )
      let capture = makeCaptureService()
      pendingCaptureService = capture
      pendingSideRecorder = recorder
      pendingCaptureStartGroup.enter()
      capture.startAudioCapture(
        audioDeviceID: plan.deviceID,
        failureHandler: { [weak self] failure in
          Task { @MainActor in self?.failureHandler(failure) }
        },
        handler: { sampleBuffer, kind in
          guard kind == .audio else { return }
          self.inputRecordingWindow.submit(sampleBuffer) { recorder.append($0) }
        },
        completionHandler: { [weak self] result in
          Task { @MainActor in
            guard let self else { return }
            if self.pendingCaptureService === capture {
              self.pendingCaptureService = nil
            }
            switch result {
            case .success:
              guard self.state == .starting else {
                capture.stop {
                  Task { @MainActor in
                    self.pendingCaptureStartGroup.leave()
                    completionHandler(.failure(CancellationError()))
                  }
                }
                return
              }
              self.captureServices.append(capture)
              self.pendingSideRecorder = nil
              self.sideRecorders.append(recorder)
              self.pendingCaptureStartGroup.leave()
              self.startAudioTrack(at: index + 1, completionHandler: completionHandler)
            case .failure(let error):
              self.pendingCaptureStartGroup.leave()
              self.failStart(
                error, displayName: plan.displayName,
                completionHandler: completionHandler)
            }
          }
        })
    } catch {
      failStart(
        error, displayName: plan.displayName,
        completionHandler: completionHandler)
    }
  }

  private func activateRecordingTimelineIfNeeded(at presentationTime: CMTime) {
    guard let origin = timelineNormalizer.activate(at: presentationTime) else { return }
    inputRecordingWindow.activate(at: origin)
  }

  private func failStart(
    _ error: Error,
    displayName: String,
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    let presented = ProgramOutputFlowInterruptionError.recordingAudioTrackUnavailable(
      displayName)
    programRecordServiceLogger.error(
      "Record service audio-track start failed: \(error.localizedDescription, privacy: .public)"
    )
    stop {
      completionHandler(.failure(error is ProgramOutputFlowInterruptionError ? error : presented))
    }
  }

  private func stopCaptures(
    at index: Int,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    guard index < captureServices.count else {
      completionHandler()
      return
    }
    captureServices[index].stop { [weak self] in
      Task { @MainActor in
        self?.stopCaptures(at: index + 1, completionHandler: completionHandler)
      }
    }
  }

  private func stopPendingCapture(
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    let completionGroup = DispatchGroup()
    if let capture = pendingCaptureService {
      pendingCaptureService = nil
      completionGroup.enter()
      capture.stop { completionGroup.leave() }
    }
    completionGroup.enter()
    pendingCaptureStartGroup.notify(queue: .global()) { completionGroup.leave() }
    completionGroup.notify(queue: .main) {
      MainActor.assumeIsolated { completionHandler() }
    }
  }

  private func finishSideRecorders(at index: Int) {
    guard index < sideRecorders.count else {
      recordingPipeline.finish { [weak self] in
        Task { @MainActor in self?.finishPackage() }
      }
      return
    }
    sideRecorders[index].finish { [weak self] in
      Task { @MainActor in self?.finishSideRecorders(at: index + 1) }
    }
  }

  private func finishPackage() {
    if recordsOutputStoppedWhenStopCompletes {
      appendDiagnosticsEvent(.outputStopped)
      recordsOutputStoppedWhenStopCompletes = false
    }
    if discardsPackageWhenStopped {
      try? diagnosticsEventLog?.close()
      discardCancelledPackage()
      completeStop()
      return
    }
    if preservesIncompletePackageWhenStopped {
      try? diagnosticsEventLog?.close()
      completeStop()
      return
    }
    do {
      try package.finish { [diagnosticsEventLog] in
        do {
          try diagnosticsEventLog?.append(.normalCompletion)
          try diagnosticsEventLog?.close()
        } catch {
          programRecordServiceLogger.error(
            "Recording diagnostics completion event was discarded: \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    } catch {
      programRecordServiceLogger.error(
        "Record package finalization failed: \(error.localizedDescription, privacy: .public)"
      )
      failureHandler(
        ProgramOutputFlowInterruptionError.recordingFinalizationFailed(
          error.localizedDescription))
    }
    completeStop()
  }

  private func discardCancelledPackage() {
    do {
      if FileManager.default.fileExists(atPath: packageDirectory.path) {
        try FileManager.default.removeItem(at: packageDirectory)
      }
    } catch {
      programRecordServiceLogger.error(
        "Cancelled record package cleanup failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func completeStop() {
    state = .stopped
    let handlers = stopHandlers
    stopHandlers.removeAll()
    for handler in handlers { handler() }
  }

  private func appendDiagnosticsEvent(_ kind: RecordingDiagnosticsEventKind) {
    do {
      try diagnosticsEventLog?.append(kind)
    } catch {
      programRecordServiceLogger.error(
        "Recording diagnostics event was discarded kind=\(kind.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func logPackagePaths() {
    programRecordServiceLogger.notice(
      "Record package created directory=\(self.packageDirectory.path, privacy: .public) audioTrackCount=\(self.audioTracks.count, privacy: .public)"
    )
  }
}

final class ProgramRecordInputRecordingWindow: @unchecked Sendable {
  private struct PendingSample {
    var sampleBuffer: CMSampleBuffer
    var output: @Sendable (CMSampleBuffer) -> Void
  }

  private let lock = NSLock()
  private var startPresentationTime: CMTime?
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
      trimPendingSamples(relativeTo: presentationTime)
      return
    }
    guard CMTimeCompare(presentationTime, startPresentationTime) >= 0 else { return }
    output(sampleBuffer)
  }

  private func trimPendingSamples(relativeTo latestPresentationTime: CMTime) {
    let earliest = CMTimeSubtract(
      latestPresentationTime, CMTime(seconds: 10, preferredTimescale: 600))
    pendingSamples.removeAll {
      CMTimeCompare($0.sampleBuffer.presentationTimeStamp, earliest) < 0
    }
  }

  func seal() {
    lock.withLock {
      isSealed = true
      pendingSamples.removeAll(keepingCapacity: false)
    }
  }
}

public enum ProgramRecordServiceError: Error, LocalizedError {
  case alreadyStarted
  case recordingPackageAlreadyExists(URL)

  public var errorDescription: String? {
    switch self {
    case .alreadyStarted: "The record service can only be started once."
    case .recordingPackageAlreadyExists(let url):
      "A recording with the same date and time ID already exists: \(url.lastPathComponent)"
    }
  }
}
