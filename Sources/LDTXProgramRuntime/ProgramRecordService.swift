// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXCapture
import LDTXMP4
import LDTXOutputMedia
import LDTXRecording
import LDTXRecordingXPCProtocol
import OSLog

private let programRecordServiceLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "record-service"
)

/// CoreMedia sample buffers have immutable payload ownership for the lifetime
/// of the callback. The input-device writer retains that payload while moving
/// it from the Capture callback queue to its private serial queue.
private struct ProgramRecordSendableSampleBuffer: @unchecked Sendable {
  let value: CMSampleBuffer
}

private final class MainRecordingFailureRelay: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (Error) -> Void)?

  func setHandler(_ handler: @escaping @Sendable (Error) -> Void) {
    lock.withLock { self.handler = handler }
  }

  func report(_ error: Error) {
    lock.withLock { handler }?(error)
  }
}

/// Serializes the Main recording XPC's configuration and finalization edges.
///
/// The service cannot drain or finish a ring before it has accepted the file
/// handles in `configureMain`. A Stop may arrive while that asynchronous
/// request is outstanding, so it is recorded and released exactly once when
/// configuration completes.
struct MainRecordingConfigurationGate: Sendable {
  private(set) var isConfiguring = false
  private var finishRequested = false

  mutating func beginConfiguration() {
    precondition(!isConfiguring)
    isConfiguring = true
  }

  /// Returns whether a deferred finalization must run now.
  mutating func completeConfiguration() -> Bool {
    precondition(isConfiguring)
    isConfiguring = false
    defer { finishRequested = false }
    return finishRequested
  }

  /// Returns whether finalization may run now. Otherwise it is released by
  /// `completeConfiguration()`.
  mutating func requestFinish() -> Bool {
    guard !isConfiguring else {
      finishRequested = true
      return false
    }
    return true
  }
}

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
public final class RecordingCoordinator {
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
  private let recordingPipeline: SeparatedProgramRecordingPipeline?
  private var mainRecorder: MainRecordingXPCClient?
  private let mainFailureRelay = MainRecordingFailureRelay()
  private var recoveredMainTracks: [(generation: Int, recorder: HLSByteRangeTrackRecorder)] = []
  private var recoveredInputAudioTracks: [
    (track: HLSByteRangeRecordingAudioTrack, generation: Int, recorder: HLSByteRangeTrackRecorder)
  ] = []
  private var nextInputAudioGeneration: [String: Int] = [:]
  private var nextMainGeneration = 2
  private var recoveryBoundaryVideo: CMSampleBuffer?
  private var recoveryAudio: [ProgramOutputAACPacket] = []
  private var isWaitingForMainRecoveryKeyFrame = false
  private var isStartingMainRecovery = false
  /// Ensures `finish` never overtakes an XPC `configureMain` request for the
  /// initial Main writer or a recovered generation.
  private var mainRecordingConfigurationGate = MainRecordingConfigurationGate()
  private let audioTracks: [ProgramRecordAudioTrack]
  private let segmentDurationSeconds: Int
  private let failureHandler: @MainActor (Error) -> Void
  private let makeCaptureService: @Sendable () -> any ProgramAudioCaptureStreaming
  private let diagnosticsEventLog: RecordingDiagnosticsEventLog?
  private var captureServices: [any ProgramAudioCaptureStreaming] = []
  private var sideRecorders: [ProgramRecordAudioWriter] = []
  private var pendingCaptureService: (any ProgramAudioCaptureStreaming)?
  private var pendingSideRecorder: ProgramRecordAudioWriter?
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
      makeCaptureService: { CameraCaptureService() },
      usesInProcessMainWriterForTesting: false)
  }

  init(
    baseDirectory: URL,
    recordID: String,
    writerConfiguration: SegmentedMP4WriterConfiguration,
    audioTracks: [ProgramRecordAudioTrack],
    diagnosticsContext: RecordingDiagnosticsContext? = nil,
    failureHandler: @escaping @MainActor (Error) -> Void,
    makeCaptureService: @escaping @Sendable () -> any ProgramAudioCaptureStreaming,
    /// This is deliberately internal: product recording always requires the
    /// embedded Main Recording XPC. Swift package tests have no app bundle in
    /// which to launch it, so they opt in to the in-process writer explicitly.
    usesInProcessMainWriterForTesting: Bool = true
  ) throws {
    packageDirectory =
      baseDirectory
      .appendingPathComponent(recordID, isDirectory: true)
      .appendingPathExtension(RecordingPackage.pathExtension)
    guard !FileManager.default.fileExists(atPath: packageDirectory.path) else {
      throw ProgramRecordServiceError.recordingPackageAlreadyExists(packageDirectory)
    }
    let mainRecordingServiceName = Bundle.main.object(
      forInfoDictionaryKey: "LDTXMainRecordingServiceXPCServiceName"
    ) as? String
    guard usesInProcessMainWriterForTesting
      || (mainRecordingServiceName?.isEmpty == false)
    else {
      // Do this before `HLSByteRangeRecordingPackage` creates its directory.
      // A product configuration error must not leave an empty recording behind.
      throw ProgramRecordServiceError.missingMainRecordingXPCService
    }
    self.audioTracks = audioTracks
    segmentDurationSeconds = writerConfiguration.segmentDurationSeconds
    self.failureHandler = failureHandler
    self.makeCaptureService = makeCaptureService

    let recordingAudioTracks = audioTracks.map {
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
        audioTracks: recordingAudioTracks
      ))
    timelineNormalizer = RecordingTimelineNormalizer()
    let xpcFailure: @Sendable (Error) -> Void = { [mainFailureRelay] error in
      programRecordServiceLogger.error(
        "Recording XPC track failed without stopping Output Session: \(error.localizedDescription, privacy: .public)"
      )
      mainFailureRelay.report(error)
    }
    if mainRecordingServiceName?.isEmpty == false {
      mainRecorder = try MainRecordingXPCClient(
        trackRecorder: package.mainTrack,
        segmentDurationSeconds: writerConfiguration.segmentDurationSeconds,
        failureHandler: xpcFailure)
      recordingPipeline = nil
    } else if usesInProcessMainWriterForTesting {
      mainRecorder = nil
      recordingPipeline = try SeparatedProgramRecordingPipeline(
        package: package,
        segmentDurationSeconds: writerConfiguration.segmentDurationSeconds,
        startNumber: writerConfiguration.startNumber,
        timelineNormalizer: timelineNormalizer,
        failureHandler: xpcFailure)
    } else {
      throw ProgramRecordServiceError.missingMainRecordingXPCService
    }
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
    mainFailureRelay.setHandler { [weak self] error in
      Task { @MainActor in self?.mainWriterFailed(error) }
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
    guard let mainRecorder else {
      startAudioTrack(at: 0, completionHandler: completionHandler)
      return
    }
    mainRecordingConfigurationGate.beginConfiguration()
    mainRecorder.start(sessionID: package.recordID) { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        let finishesNow = self.mainRecordingConfigurationGate.completeConfiguration()
        switch result {
        case .success:
          guard self.state == .starting else {
            self.finishDeferredMainRecorderIfNeeded(finishesNow)
            return
          }
          self.startAudioTrack(at: 0, completionHandler: completionHandler)
        case .failure(let error):
          self.mainRecorder = nil
          self.finishDeferredMainRecorderIfNeeded(finishesNow)
          self.failMainWriterStart(error, completionHandler: completionHandler)
        }
      }
    }
  }

  public func appendMainVideo(_ sampleBuffer: CMSampleBuffer) {
    guard state == .writing else { return }
    activateRecordingTimelineIfNeeded(at: sampleBuffer.presentationTimeStamp)
    if isWaitingForMainRecoveryKeyFrame || recoveryBoundaryVideo != nil || isStartingMainRecovery {
      handleVideoDuringMainRecovery(sampleBuffer)
      return
    }
    if let mainRecorder {
      timelineNormalizer.submit(sampleBuffer, trackID: "main-video") { normalized in
        mainRecorder.appendVideo(normalized)
      }
    } else {
      recordingPipeline?.appendVideo(sampleBuffer)
    }
  }

  public func appendProgramAudio(_ packet: ProgramOutputAACPacket) {
    guard state == .writing else { return }
    let presentationTime = CMTime(
      value: CMTimeValue(packet.accessUnit.presentationTime.value),
      timescale: CMTimeScale(packet.accessUnit.presentationTime.timescale))
    activateRecordingTimelineIfNeeded(at: presentationTime)
    if isWaitingForMainRecoveryKeyFrame || recoveryBoundaryVideo != nil || isStartingMainRecovery {
      appendRecoveryAudio(packet)
      return
    }
    if let mainRecorder {
      guard let normalized = timelineNormalizer.normalized(packet) else { return }
      mainRecorder.appendProgramAudio(normalized)
    } else {
      recordingPipeline?.appendProgramAudio(packet)
    }
  }

  /// Closes the raw-input side of this recording at the Output Session's stop
  /// boundary. Main-stream encoders may still flush already accepted samples.
  public nonisolated func sealInputAudio() {
    inputRecordingWindow.seal()
  }

  /// Temporarily holds input-device audio while the Output Session waits for
  /// the video keyframe that will define a Cut boundary.
  public nonisolated func prepareInputAudioCut() {
    inputRecordingWindow.prepareCut()
  }

  /// Finishes input-device audio immediately before the shared video Cut PTS.
  public nonisolated func sealInputAudio(before presentationTime: CMTime) {
    inputRecordingWindow.seal(before: presentationTime)
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
      let sideRecorder = try AudioSideStreamRecorder(
        trackRecorder: trackRecorder,
        segmentDurationSeconds: segmentDurationSeconds,
        onFailure: { [weak self] error in
          Task { @MainActor in self?.inputAudioWriterFailed(plan, error: error) }
        }
      )
      let recorder = ProgramRecordAudioWriter(
        track: plan,
        recorder: sideRecorder,
        onFailure: { [weak self] error in
          Task { @MainActor in self?.inputAudioWriterFailed(plan, error: error) }
        })
      let capture = makeCaptureService()
      pendingCaptureService = capture
      pendingSideRecorder = recorder
      pendingCaptureStartGroup.enter()
      recorder.start(sessionID: package.recordID) { [weak self] writerResult in
        Task { @MainActor in
          guard let self else { return }
          if case .failure(let error) = writerResult {
            self.pendingCaptureStartGroup.leave()
            self.failStart(
              error, displayName: plan.displayName,
              completionHandler: completionHandler)
            return
          }
          capture.startAudioCapture(
            audioDeviceID: plan.deviceID,
            failureHandler: { [weak self] failure in
              Task { @MainActor in self?.failureHandler(failure) }
            },
            handler: { sampleBuffer, kind in
              guard kind == .audio else { return }
              self.inputRecordingWindow.submit(sampleBuffer) {
                [timelineNormalizer = self.timelineNormalizer] sample in
                timelineNormalizer.submit(sample, trackID: plan.trackID) { normalized in
                  recorder.append(normalized)
                }
              }
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
        }
      }
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

  /// A Main writer failure is isolated from Output and YouTube.  We wait for a
  /// natural sync sample so the recovered fMP4 starts at a decodable GOP.
  private func mainWriterFailed(_ error: Error) {
    guard state == .writing, mainRecorder != nil else { return }
    guard !isWaitingForMainRecoveryKeyFrame, recoveryBoundaryVideo == nil, !isStartingMainRecovery else { return }
    mainRecorder = nil
    isWaitingForMainRecoveryKeyFrame = true
    recoveryAudio.removeAll(keepingCapacity: true)
    programRecordServiceLogger.error(
      "Main recording writer will recover at next keyframe: \(error.localizedDescription, privacy: .public)"
    )
  }

  /// Input-device recording is deliberately isolated from the Program output:
  /// a disk/writer error replaces only this device's `.m4a` at the next input
  /// sample. Its recovered file is represented as a separate DASH Period.
  private func inputAudioWriterFailed(_ plan: ProgramRecordAudioTrack, error: Error) {
    guard state == .writing, let writer = sideRecorders.first(where: { $0.track.key == plan.key }) else {
      return
    }
    let generation = nextInputAudioGeneration[plan.trackID, default: 2]
    nextInputAudioGeneration[plan.trackID] = generation + 1
    let track = makeRecordingAudioTrack(plan)
    do {
      let recorderTrack = try package.makeInputAudioGenerationTrack(track, generation: generation)
      let recorder = try AudioSideStreamRecorder(
        trackRecorder: recorderTrack,
        segmentDurationSeconds: segmentDurationSeconds,
        onFailure: { [weak self] error in
          Task { @MainActor in self?.inputAudioWriterFailed(plan, error: error) }
        }
      )
      writer.replace(recorder)
      recoveredInputAudioTracks.append((track, generation, recorderTrack))
      programRecordServiceLogger.error(
        "Input audio writer recovered track=\(plan.trackID, privacy: .public) generation=\(generation) after error=\(error.localizedDescription, privacy: .public)"
      )
    } catch {
      programRecordServiceLogger.error(
        "Input audio writer recovery could not allocate track=\(plan.trackID, privacy: .public) generation=\(generation): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func makeRecordingAudioTrack(_ plan: ProgramRecordAudioTrack) -> HLSByteRangeRecordingAudioTrack {
    HLSByteRangeRecordingAudioTrack(
      id: plan.trackID,
      displayName: plan.displayName,
      fileNameStem: plan.fileNameStem
    )
  }

  private func handleVideoDuringMainRecovery(_ sampleBuffer: CMSampleBuffer) {
    guard isWaitingForMainRecoveryKeyFrame else { return }
    guard Self.isVideoKeyFrame(sampleBuffer) else { return }
    recoveryBoundaryVideo = sampleBuffer
    isWaitingForMainRecoveryKeyFrame = false
    startMainRecovery()
  }

  /// A failed writer can wait up to a GOP for a decodable boundary. Keep only
  /// a bounded tail of Program AAC during that interval; recording must never
  /// make the live output path allocate without bound.
  private func appendRecoveryAudio(_ packet: ProgramOutputAACPacket) {
    recoveryAudio.append(packet)
    let maximumBufferedSamples = 512
    if recoveryAudio.count > maximumBufferedSamples {
      recoveryAudio.removeFirst(recoveryAudio.count - maximumBufferedSamples)
    }
  }

  private func startMainRecovery() {
    guard !isStartingMainRecovery, recoveryBoundaryVideo != nil else { return }
    isStartingMainRecovery = true
    mainRecordingConfigurationGate.beginConfiguration()
    let generation = nextMainGeneration
    nextMainGeneration += 1
    do {
      let track = try package.makeMainGenerationTrack(generation: generation)
      let recorder = try MainRecordingXPCClient(
        trackRecorder: track,
        segmentDurationSeconds: segmentDurationSeconds,
        failureHandler: { [mainFailureRelay] error in mainFailureRelay.report(error) }
      )
      recoveredMainTracks.append((generation, track))
      mainRecorder = recorder
      recorder.start(sessionID: package.recordID, generation: generation) { [weak self] result in
        Task { @MainActor in
          guard let self else { return }
          self.isStartingMainRecovery = false
          let finishesNow = self.mainRecordingConfigurationGate.completeConfiguration()
          switch result {
          case .success:
            guard self.mainRecorder === recorder else { return }
            guard self.state == .writing, let boundary = self.recoveryBoundaryVideo else {
              self.recoveryBoundaryVideo = nil
              self.recoveryAudio.removeAll(keepingCapacity: true)
              self.finishDeferredMainRecorderIfNeeded(finishesNow)
              return
            }
            self.timelineNormalizer.submit(boundary, trackID: "main-video") { normalized in
              recorder.appendVideo(normalized)
            }
            for audio in self.recoveryAudio where
              CMTimeCompare(
                CMTime(value: CMTimeValue(audio.accessUnit.presentationTime.value), timescale: CMTimeScale(audio.accessUnit.presentationTime.timescale)),
                boundary.presentationTimeStamp) >= 0
            {
              if let normalized = self.timelineNormalizer.normalized(audio) {
                recorder.appendProgramAudio(normalized)
              }
            }
            self.recoveryBoundaryVideo = nil
            self.recoveryAudio.removeAll(keepingCapacity: true)
          case .failure(let error):
            self.mainRecorder = nil
            self.recoveryBoundaryVideo = nil
            self.recoveryAudio.removeAll(keepingCapacity: true)
            self.isWaitingForMainRecoveryKeyFrame = self.state == .writing
            programRecordServiceLogger.error(
              "Main recording recovery setup failed; waiting for a later keyframe: \(error.localizedDescription, privacy: .public)"
            )
          }
          self.finishDeferredMainRecorderIfNeeded(finishesNow)
        }
      }
    } catch {
      isStartingMainRecovery = false
      _ = mainRecordingConfigurationGate.completeConfiguration()
      recoveryBoundaryVideo = nil
      recoveryAudio.removeAll(keepingCapacity: true)
      isWaitingForMainRecoveryKeyFrame = state == .writing
      programRecordServiceLogger.error(
        "Main recording recovery allocation failed; waiting for a later keyframe: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private static func isVideoKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]], let first = attachments.first else { return true }
    return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
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

  private func failMainWriterStart(
    _ error: Error,
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    let presented = Self.mainWriterStartError(error)
    programRecordServiceLogger.error(
      "Record service main writer start failed: \(error.localizedDescription, privacy: .public)"
    )
    stop {
      completionHandler(.failure(presented))
    }
  }

  nonisolated static func mainWriterStartError(
    _ error: Error
  ) -> ProgramOutputFlowInterruptionError {
    .recordingWriterFailed(error.localizedDescription)
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
      finishMainRecorders()
      return
    }
    sideRecorders[index].finish { [weak self] in
      Task { @MainActor in self?.finishSideRecorders(at: index + 1) }
    }
  }

  private func finishMainRecorders() {
    guard mainRecordingConfigurationGate.requestFinish() else { return }
    if let mainRecorder {
      finish(mainRecorder: mainRecorder)
    } else if let recordingPipeline {
      recordingPipeline.finish { [weak self] in
        Task { @MainActor in self?.finishPackage() }
      }
    } else {
      // A failed Main Recording XPC must not prevent finalization of its
      // already durable generations and the independently recorded inputs.
      finishPackage()
    }
  }

  private func finishDeferredMainRecorderIfNeeded(_ finishesNow: Bool) {
    guard finishesNow else { return }
    finishMainRecorders()
  }

  private func finish(mainRecorder: MainRecordingXPCClient) {
    mainRecorder.finish { [weak self] _ in
      Task { @MainActor in self?.finishPackage() }
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
      for entry in recoveredMainTracks {
        entry.recorder.finish()
      }
      let recoveryPeriods = recoveredMainTracks.compactMap { entry in
        entry.recorder.durableSnapshot().map {
          HLSByteRangeRecordingPeriod(id: "generation-\(entry.generation)", main: $0, audio: [])
        }
      }
      let inputRecoveryPeriods = recoveredInputAudioTracks.compactMap { entry in
        entry.recorder.finish()
        return entry.recorder.durableSnapshot().map {
          HLSByteRangeRecordingPeriod(
            id: "input-\(entry.track.id)-generation-\(entry.generation)",
            main: nil,
            audio: [(entry.track, $0)]
          )
        }
      }
      try package.completeSession(additionalPeriods: recoveryPeriods + inputRecoveryPeriods) { [diagnosticsEventLog] in
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
        "Record package session completion failed: \(error.localizedDescription, privacy: .public)"
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

/// Backpressure state for one input-device writer. It is deliberately a small
/// value type so the realtime admission decision can be unit tested without
/// AVFoundation or a capture device.
struct InputDeviceAudioRecordingBacklog: Sendable {
  enum Admission: Sendable, Equatable {
    case accepted
    case overflow
    case dropped
  }

  /// Capture callbacks must not wait for AVFoundation or disk work.  This is
  /// deliberately bounded: when a device writer cannot keep up, only that
  /// device recording recovers to a new generation; the Capture and Program
  /// output paths remain realtime.
  static let maximumQueuedSamples = 256

  private(set) var queuedSampleCount = 0
  private var isFinishing = false
  private var overflowReported = false

  mutating func admit() -> Admission {
    guard !isFinishing else { return .dropped }
    guard queuedSampleCount < Self.maximumQueuedSamples else {
      guard !overflowReported else { return .dropped }
      overflowReported = true
      return .overflow
    }
    queuedSampleCount += 1
    return .accepted
  }

  mutating func completeSample() {
    precondition(queuedSampleCount > 0)
    queuedSampleCount -= 1
    // Do not create another recovery generation while the existing backlog
    // remains saturated. A newly available slot is the only safe point to
    // allow one future overflow notification.
    if queuedSampleCount < Self.maximumQueuedSamples {
      overflowReported = false
    }
  }

  mutating func beginFinishing() -> Bool {
    guard !isFinishing else { return false }
    isFinishing = true
    return true
  }

  mutating func recoveredGenerationStarted() -> Bool {
    guard !isFinishing else { return false }
    return true
  }
}

private final class ProgramRecordAudioWriter: @unchecked Sendable {

  let track: ProgramRecordAudioTrack
  private let lock = NSLock()
  private let queue: DispatchQueue
  private let onFailure: @Sendable (Error) -> Void
  private var recorders: [AudioSideStreamRecorder]
  private var backlog = InputDeviceAudioRecordingBacklog()

  init(
    track: ProgramRecordAudioTrack,
    recorder: AudioSideStreamRecorder,
    onFailure: @escaping @Sendable (Error) -> Void
  ) {
    self.track = track
    recorders = [recorder]
    self.onFailure = onFailure
    queue = DispatchQueue(label: "tokyo.kaito.ldtx.input-audio-recording.\(track.trackID)")
  }

  func start(
    sessionID _: String,
    completionHandler: @escaping @Sendable (Result<Void, Error>) -> Void
  ) {
    completionHandler(.success(()))
  }

  func append(_ sampleBuffer: CMSampleBuffer) {
    let admission = lock.withLock { backlog.admit() }
    guard admission == .accepted else {
      if admission == .overflow {
        onFailure(ProgramRecordAudioWriterError.backlogExceeded(track.displayName))
      }
      return
    }
    let sample = ProgramRecordSendableSampleBuffer(value: sampleBuffer)
    queue.async { [weak self] in
      guard let self else { return }
      let recorder = self.lock.withLock { self.recorders.last }
      recorder?.append(sample.value)
      self.lock.withLock { self.backlog.completeSample() }
    }
  }

  func replace(_ recorder: AudioSideStreamRecorder) {
    lock.withLock {
      guard backlog.recoveredGenerationStarted() else { return }
      recorders.append(recorder)
    }
  }

  func finish(completionHandler: @escaping @Sendable () -> Void) {
    let shouldFinish = lock.withLock { backlog.beginFinishing() }
    guard shouldFinish else {
      completionHandler()
      return
    }
    // A serial queue barrier preserves every callback already accepted before
    // Stop, then begins writer finalization without blocking the caller.
    queue.async { [weak self] in
      guard let self else {
        completionHandler()
        return
      }
      let snapshot = self.lock.withLock { self.recorders }
      self.finish(snapshot, at: 0, completionHandler: completionHandler)
    }
  }

  private func finish(
    _ recorders: [AudioSideStreamRecorder],
    at index: Int,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    guard index < recorders.count else {
      completionHandler()
      return
    }
    recorders[index].finish { [weak self] in
      self?.finish(recorders, at: index + 1, completionHandler: completionHandler)
    }
  }
}

private enum ProgramRecordAudioWriterError: LocalizedError {
  case backlogExceeded(String)

  var errorDescription: String? {
    switch self {
    case .backlogExceeded(let displayName):
      "Input audio recording backlog exceeded its bounded capacity for \(displayName)."
    }
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
  private var isPreparingCut = false
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
    if isPreparingCut {
      pendingSamples.append(PendingSample(sampleBuffer: sampleBuffer, output: output))
      trimPendingSamples(relativeTo: presentationTime)
      return
    }
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

  func prepareCut() {
    lock.withLock {
      guard !isSealed else { return }
      isPreparingCut = true
    }
  }

  func seal(before presentationTime: CMTime) {
    guard presentationTime.isNumeric else {
      seal()
      return
    }
    lock.lock()
    defer { lock.unlock() }
    guard !isSealed else { return }
    isSealed = true
    isPreparingCut = false
    let accepted = pendingSamples.filter {
      CMTimeCompare($0.sampleBuffer.presentationTimeStamp, presentationTime) < 0
    }
    pendingSamples.removeAll(keepingCapacity: false)
    for sample in accepted {
      sample.output(sample.sampleBuffer)
    }
  }
}

public typealias ProgramRecordService = RecordingCoordinator

public enum ProgramRecordServiceError: Error, LocalizedError {
  case alreadyStarted
  case recordingPackageAlreadyExists(URL)
  case missingMainRecordingXPCService

  public var errorDescription: String? {
    switch self {
    case .alreadyStarted: "The record service can only be started once."
    case .recordingPackageAlreadyExists(let url):
      "A recording with the same date and time ID already exists: \(url.lastPathComponent)"
    case .missingMainRecordingXPCService:
      "The embedded Main Recording XPC service is unavailable."
    }
  }
}
