// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXCapture
import LDTXDash
import LDTXMP4
import LDTXProgram
import LDTXYouTubeOutputProtocol
import OSLog

private let programOutputLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "program-output"
)

private func dispatchToProgramOutputMainActor(
  _ operation: @escaping @MainActor @Sendable () -> Void
) {
  DispatchQueue.main.async {
    MainActor.assumeIsolated {
      operation()
    }
  }
}

public enum ProgramOutputSessionError: Error, LocalizedError {
  case sessionAlreadyUsed
  case recordingPackageAlreadyExists(URL)
  case outputServiceRecoveryExhausted(String)

  public var errorDescription: String? {
    switch self {
    case .sessionAlreadyUsed:
      "An output session can only be started once. Create a new session for each output."
    case .recordingPackageAlreadyExists(let url):
      "A recording with the same date and time ID already exists: \(url.lastPathComponent)"
    case .outputServiceRecoveryExhausted(let reason):
      "The output service cannot be recovered: \(reason)"
    }
  }

  public var requiresImmediateGlobalStop: Bool {
    if case .outputServiceRecoveryExhausted = self { return true }
    return false
  }
}

@MainActor
public final class ProgramDASHStreamContinuityStore {
  private var localState: DASHStreamContinuityState?
  private var statesByEndpointIdentity: [String: DASHStreamContinuityState] = [:]

  public init() {}

  func state(endpointIdentity: String?) -> DASHStreamContinuityState? {
    guard let endpointIdentity else { return localState }
    return statesByEndpointIdentity[endpointIdentity]
  }

  func setState(_ state: DASHStreamContinuityState?, endpointIdentity: String?) {
    guard let endpointIdentity else {
      localState = state
      return
    }
    statesByEndpointIdentity[endpointIdentity] = state
  }
}

@MainActor
public final class ProgramOutputSession {
  private enum LifecycleState {
    case idle
    case starting
    case running
    case stopping
    case stopped
  }

  private struct AudioTrackPlan {
    var key: String
    var trackID: String
    var deviceID: String
  }

  public let id: UUID
  private let activeProgramRuntime: ActiveProgramRuntime
  private let continuityStore: ProgramDASHStreamContinuityStore
  private var shutdownCompletionHandlers: [@MainActor @Sendable () -> Void] = []
  private var frameStreamID: UUID?
  private var uploadPipeline: ProgramYouTubeOutputXPCSink?
  private var videoEncoder: H264VideoEncoder?
  private var videoFanout: ProgramEncodedVideoFanout?
  private var mediaBatcher: YouTubeOutputMediaBatcher?
  private var recordingPipeline: SeparatedProgramRecordingPipeline?
  private var audioOutputSampleHandlerID: UUID?
  private var recordingPackage: HLSByteRangeRecordingPackage?
  private var recordingSplitState: RecordingSplitState?
  private var audioRenderer: ProgramAudioMonitor?
  private var audioCaptureServices: [CameraCaptureService] = []
  private var audioSideRecordersByTrackID: [String: AudioSideStreamRecorder] = [:]
  private var activeEventHandler: (@MainActor (String) -> Void)?
  private var activeFailureHandler: (@MainActor (Error) -> Void)?
  private var pendingStartCompletionHandler:
    (@MainActor @Sendable (Result<Void, any Error>) -> Void)?
  private var pendingRecordingSplit = false
  private var lifecycleState: LifecycleState = .idle
  private var continuityEndpointIdentity: String?

  public init(
    id: UUID = UUID(),
    activeProgramRuntime: ActiveProgramRuntime,
    continuityStore: ProgramDASHStreamContinuityStore = ProgramDASHStreamContinuityStore()
  ) {
    self.id = id
    self.activeProgramRuntime = activeProgramRuntime
    self.continuityStore = continuityStore
  }

  private var continuityState: DASHStreamContinuityState? {
    get { continuityStore.state(endpointIdentity: continuityEndpointIdentity) }
    set { continuityStore.setState(newValue, endpointIdentity: continuityEndpointIdentity) }
  }

  public var isRunning: Bool {
    lifecycleState == .running
  }

  public var currentRecordingPackageDirectory: URL? {
    guard isRunning else { return nil }
    return recordingPackage?.directory
  }

  @discardableResult
  public func requestRecordingSplit() -> Bool {
    guard isRunning, recordingPackage != nil, recordingSplitState != nil else {
      return false
    }
    pendingRecordingSplit = true
    return true
  }

  public func start(
    snapshot: ProgramPreviewSnapshot,
    endpoint: DASHIngestEndpoint?,
    recordingBaseDirectory: URL?,
    programPreferences: ProgramPreferences,
    audioDeviceIDsByInputKey: [String: String],
    audioRenderer: ProgramAudioMonitor,
    eventHandler: @escaping @MainActor (String) -> Void,
    failureHandler: @escaping @MainActor (Error) -> Void,
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard lifecycleState == .idle else {
      programOutputLogger.error(
        "[session:\(self.id.uuidString, privacy: .public)] [event:output.start.rejected] reason=session-already-used"
      )
      completionHandler(.failure(ProgramOutputSessionError.sessionAlreadyUsed))
      return
    }
    lifecycleState = .starting
    pendingStartCompletionHandler = completionHandler
    continuityEndpointIdentity = endpoint?.baseURL.absoluteString

    do {

      let frameRate = max(snapshot.frameRate, 1)
      let audioTrackPlans = audioTrackPlans(from: audioDeviceIDsByInputKey)
      let baseWriterConfiguration = SegmentedMP4WriterConfiguration(
        width: snapshot.outputWidth,
        height: snapshot.outputHeight,
        frameRate: frameRate,
        videoBitRate: videoBitRate(
          width: snapshot.outputWidth, height: snapshot.outputHeight, frameRate: frameRate)
      )
      let outputConfigurationFingerprint = DASHStreamOutputConfigurationFingerprint(
        writerConfiguration: baseWriterConfiguration,
        audioTrackIDs: audioTrackPlans.map(\.trackID)
      )
      var continuityState = resolvedContinuityState(
        endpoint: endpoint,
        outputConfigurationFingerprint: outputConfigurationFingerprint
      )
      let writerConfiguration = SegmentedMP4WriterConfiguration(
        width: baseWriterConfiguration.width,
        height: baseWriterConfiguration.height,
        frameRate: baseWriterConfiguration.frameRate,
        videoBitRate: baseWriterConfiguration.videoBitRate,
        videoPixelBufferPoolMinimumBufferCount: baseWriterConfiguration
          .videoPixelBufferPoolMinimumBufferCount,
        audioSampleRate: baseWriterConfiguration.audioSampleRate,
        audioChannelCount: baseWriterConfiguration.audioChannelCount,
        audioBitRate: baseWriterConfiguration.audioBitRate,
        segmentDurationSeconds: baseWriterConfiguration.segmentDurationSeconds,
        timescale: baseWriterConfiguration.timescale,
        startNumber: continuityState.nextMediaSegmentNumber
      )
      continuityState.outputConfigurationFingerprint = outputConfigurationFingerprint
      self.continuityState = continuityState
      pendingRecordingSplit = false
      activeEventHandler = eventHandler
      activeFailureHandler = failureHandler

      let serviceReadyRelay = ProgramYouTubeOutputReadyRelay()
      let pipeline: ProgramYouTubeOutputXPCSink? =
        if let endpoint {
          ProgramYouTubeOutputXPCSink(
            bootstrap: outputServiceBootstrap(
              endpoint: endpoint,
              continuityState: continuityState,
              configurationFingerprint: outputConfigurationFingerprint.outputServiceValue,
              writerConfiguration: writerConfiguration,
              width: snapshot.outputWidth,
              height: snapshot.outputHeight,
              frameRate: frameRate
            ),
            eventHandler: { message in
              dispatchToProgramOutputMainActor { eventHandler(message) }
            },
            failureHandler: { error in
              dispatchToProgramOutputMainActor { [weak self] in
                if let error = error as? OutputXPCError, error.requiresGlobalStop {
                  self?.handleOutputFailure(
                    ProgramOutputSessionError.outputServiceRecoveryExhausted(
                      error.localizedDescription))
                } else {
                  self?.handleOutputFailure(error)
                }
              }
            },
            readyHandler: { serviceReadyRelay.requestKeyFrame() },
            checkpointHandler: { [weak self] checkpoint in
              dispatchToProgramOutputMainActor {
                self?.applyYouTubeOutputCheckpoint(checkpoint)
              }
            }
          )
        } else {
          nil
        }
      uploadPipeline = pipeline
      let batcher = pipeline.map {
        YouTubeOutputMediaBatcher(sessionID: id, sink: $0) { error in
          dispatchToProgramOutputMainActor { [weak self] in self?.handleOutputFailure(error) }
        }
      }
      mediaBatcher = batcher
      let fanout = ProgramEncodedVideoFanout(failureHandler: { error in
        dispatchToProgramOutputMainActor { [weak self] in self?.handleOutputFailure(error) }
      })
      fanout.mediaBatcher = batcher
      videoFanout = fanout
      let encoder = try H264VideoEncoder(
        configuration: H264VideoEncoderConfiguration(
          width: writerConfiguration.width,
          height: writerConfiguration.height,
          frameRate: writerConfiguration.frameRate,
          bitRate: writerConfiguration.videoBitRate,
          keyFrameIntervalSeconds: writerConfiguration.segmentDurationSeconds
        )
      ) { fanout.receive($0) }
      videoEncoder = encoder
      serviceReadyRelay.encoder = encoder
      self.audioRenderer = audioRenderer
      audioRenderer.updateGains(
        audioChannels: snapshot.audioChannels, preferences: programPreferences)
      programOutputLogger.notice(
        "[session:\(self.id.uuidString, privacy: .public)] [event:output.starting] videoPTSSource=\(snapshot.programVideoPTSInputKey ?? "host-clock", privacy: .public), audioDriver=independent-pull, audioTiming=absolute-deadline-200ms, audioChannelCount=\(snapshot.audioChannels.count, privacy: .public)"
      )

      let prepareRecording: @Sendable () -> Void = { [weak self] in
        dispatchToProgramOutputMainActor {
          self?.prepareRecordingAndCompleteStart(
            recordingBaseDirectory: recordingBaseDirectory,
            audioTrackPlans: audioTrackPlans,
            writerConfiguration: writerConfiguration,
            fanout: fanout,
            encoder: encoder,
            snapshot: snapshot,
            frameRate: frameRate,
            audioRenderer: audioRenderer,
            eventHandler: eventHandler,
            failureHandler: failureHandler)
        }
      }
      if let pipeline {
        pipeline.whenReady(prepareRecording)
      } else {
        prepareRecording()
      }
    } catch {
      failStart(error)
    }
  }

  private func prepareRecordingAndCompleteStart(
    recordingBaseDirectory: URL?,
    audioTrackPlans: [AudioTrackPlan],
    writerConfiguration: SegmentedMP4WriterConfiguration,
    fanout: ProgramEncodedVideoFanout,
    encoder: H264VideoEncoder,
    snapshot: ProgramPreviewSnapshot,
    frameRate: Int,
    audioRenderer: ProgramAudioMonitor,
    eventHandler: @escaping @MainActor (String) -> Void,
    failureHandler: @escaping @MainActor (Error) -> Void
  ) {
    do {
      try ensureSessionIsStarting()
      if let recordingBaseDirectory {
        let recordID = Self.recordID(date: Date())
        let sideRecordingTracks = audioTrackPlans.enumerated().map { index, plan in
          let fileNameStem = index == 0 ? "side-track" : "side-track-\(index + 1)"
          return HLSByteRangeRecordingAudioTrack(
            id: plan.trackID,
            displayName: plan.key,
            fileNameStem: fileNameStem
          )
        }
        let recordingAudioTracks =
          [
            HLSByteRangeRecordingAudioTrack(
              id: SeparatedProgramRecordingPipeline.mainAudioTrackID,
              displayName: "Main Mix",
              fileNameStem: "main-audio"
            )
          ] + sideRecordingTracks
        let initialSplitState = RecordingSplitState(
          baseDirectory: recordingBaseDirectory,
          packageConfiguration: HLSByteRangeRecordingPackageConfiguration(
            directory: RecordingSplitState.directoryURL(
              baseDirectory: recordingBaseDirectory,
              recordID: recordID
            ),
            recordID: recordID,
            targetDurationSeconds: writerConfiguration.segmentDurationSeconds,
            videoCodecs: "avc1.64002a",
            audioCodecs: "mp4a.40.2",
            bandwidth: writerConfiguration.videoBitRate + writerConfiguration.audioBitRate,
            includesMainAudioTrack: false,
            audioTracks: recordingAudioTracks
          )
        )
        let package = try makeRecordingPackage(
          configuration: initialSplitState.packageConfiguration,
          directory: initialSplitState.packageConfiguration.directory
        )
        recordingPackage = package
        recordingSplitState = initialSplitState
        let recordingPipeline = try SeparatedProgramRecordingPipeline(
          package: package,
          segmentDurationSeconds: writerConfiguration.segmentDurationSeconds,
          startNumber: writerConfiguration.startNumber,
          failureHandler: { error in
            dispatchToProgramOutputMainActor { [weak self] in self?.handleOutputFailure(error) }
          },
          mediaSegmentHandler: { [weak self] in
            dispatchToProgramOutputMainActor {
              guard let self else { return }
              do { try self.performPendingRecordingSplitIfNeeded() } catch {
                self.activeFailureHandler?(error)
                self.stop()
              }
            }
          }
        )
        self.recordingPipeline = recordingPipeline
        fanout.recordingPipeline = recordingPipeline
        logRecordingPackagePaths(package: package, sideRecordingTracks: sideRecordingTracks)
        startAudioSideStreams(
          plans: audioTrackPlans,
          index: 0,
          excludingTrackIDs: [],
          package: package,
          segmentDurationSeconds: writerConfiguration.segmentDurationSeconds,
          eventHandler: eventHandler
        ) { [self] in
          do {
            try ensureSessionIsStarting()
            eventHandler("Recording package started: \(package.directory.path)")
            completeStart(
              encoder: encoder,
              snapshot: snapshot,
              frameRate: frameRate,
              audioRenderer: audioRenderer,
              eventHandler: eventHandler,
              failureHandler: failureHandler
            )
          } catch {
            failStart(error)
          }
        }
        return
      } else {
        recordingSplitState = nil
      }

      completeStart(
        encoder: encoder,
        snapshot: snapshot,
        frameRate: frameRate,
        audioRenderer: audioRenderer,
        eventHandler: eventHandler,
        failureHandler: failureHandler
      )
    } catch {
      failStart(error)
    }
  }

  private func completeStart(
    encoder: H264VideoEncoder,
    snapshot: ProgramPreviewSnapshot,
    frameRate: Int,
    audioRenderer: ProgramAudioMonitor,
    eventHandler: @escaping @MainActor (String) -> Void,
    failureHandler: @escaping @MainActor (Error) -> Void
  ) {
    activateOutput(
      encoder: encoder,
      snapshot: snapshot,
      audioRenderer: audioRenderer)
  }

  private func activateOutput(
    encoder: H264VideoEncoder,
    snapshot: ProgramPreviewSnapshot,
    audioRenderer: ProgramAudioMonitor
  ) {
    do {
      try ensureSessionIsStarting()
    } catch {
      failStart(error)
      return
    }
    activeProgramRuntime.beginOutput(snapshot: snapshot)
    let recordingPipeline = recordingPipeline
    let mediaBatcher = mediaBatcher
    audioOutputSampleHandlerID = audioRenderer.addOutputSampleHandler { sampleBuffer in
      recordingPipeline?.appendAudio(sampleBuffer)
      mediaBatcher?.appendAudio(sampleBuffer)
    }
    let frameSink = ProgramOutputVideoFrameSink(
      outputSessionID: id,
      encoder: encoder,
      audioRenderer: audioRenderer,
      videoPTSSourceKey: snapshot.programVideoPTSInputKey
    )
    self.frameStreamID = activeProgramRuntime.addFrameHandler { frame in
      frameSink.consume(frame)
    }
    lifecycleState = .running
    programOutputLogger.notice(
      "[session:\(self.id.uuidString, privacy: .public)] [event:output.started]"
    )
    completePendingStart(.success(()))
  }

  private func outputServiceBootstrap(
    endpoint: DASHIngestEndpoint,
    continuityState: DASHStreamContinuityState,
    configurationFingerprint: String,
    writerConfiguration: SegmentedMP4WriterConfiguration,
    width: Int,
    height: Int,
    frameRate: Int
  ) -> YouTubeOutputBootstrap {
    let representation = dashRepresentation(
      width: width,
      height: height,
      frameRate: frameRate,
      videoBitRate: writerConfiguration.videoBitRate
    )
    return YouTubeOutputBootstrap(
      context: YouTubeOutputContext(sessionID: id, generation: 0),
      endpoint: endpoint.baseURL,
      availabilityStartTime: continuityState.availabilityStartTime,
      timescale: writerConfiguration.timescale,
      segmentDurationSeconds: writerConfiguration.segmentDurationSeconds,
      startNumber: writerConfiguration.startNumber,
      mediaTemplate: endpoint.mpdReference(for: "media$Number%09d$.mp4"),
      representation: YouTubeOutputRepresentation(
        id: representation.id,
        bandwidth: representation.bandwidth,
        width: representation.width,
        height: representation.height,
        frameRate: representation.frameRate,
        codecs: representation.codecs,
        audioSamplingRate: representation.audioSamplingRate
      ),
      configurationFingerprint: configurationFingerprint,
      initializationSegment: continuityState.latestInitSegment
    )
  }

  private func applyYouTubeOutputCheckpoint(_ checkpoint: YouTubeOutputCheckpoint) {
    guard var state = continuityState, state.apply(checkpoint) else { return }
    continuityState = state
  }

  public func stop(
    completionHandler: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    if lifecycleState == .stopped || lifecycleState == .idle {
      completionHandler()
      return
    }
    if lifecycleState == .stopping {
      shutdownCompletionHandlers.append(completionHandler)
      return
    }
    guard lifecycleState == .starting || lifecycleState == .running else {
      completionHandler()
      return
    }
    let wasStarting = lifecycleState == .starting
    lifecycleState = .stopping
    if wasStarting {
      completePendingStart(.failure(CancellationError()))
    }
    programOutputLogger.notice(
      "[session:\(self.id.uuidString, privacy: .public)] [event:output.stopping]"
    )
    shutdownCompletionHandlers.append(completionHandler)

    if let frameStreamID {
      activeProgramRuntime.removeFrameHandler(id: frameStreamID)
    }
    activeProgramRuntime.endOutput()

    let videoEncoder = videoEncoder
    let mediaBatcher = mediaBatcher
    let recordingPipeline = recordingPipeline
    let uploadPipeline = uploadPipeline
    if let audioOutputSampleHandlerID {
      audioRenderer?.removeOutputSampleHandler(id: audioOutputSampleHandlerID)
    }
    let audioCaptureServices = audioCaptureServices
    let audioSideRecordersByTrackID = audioSideRecordersByTrackID
    let recordingPackage = recordingPackage
    let failureHandler = activeFailureHandler
    pendingRecordingSplit = false

    stopCaptureServices(audioCaptureServices, index: 0) { [weak self] in
      self?.finishSideRecorders(
        Array(audioSideRecordersByTrackID.values),
        index: 0
      ) { [weak self] in
        self?.finishEncoder(videoEncoder, failureHandler: failureHandler) { [weak self] in
          self?.finishMediaBatcher(mediaBatcher) { [weak self] in
            self?.finishRecordingPipeline(recordingPipeline) { [weak self] in
              guard let uploadPipeline else {
                recordingPackage?.finish()
                self?.completeShutdown()
                return
              }
              uploadPipeline.finish {
                dispatchToProgramOutputMainActor {
                  recordingPackage?.finish()
                  self?.completeShutdown()
                }
              }
            }
          }
        }
      }
    }
  }

  private func handleOutputFailure(_ error: Error) {
    if lifecycleState == .stopping {
      activeFailureHandler?(error)
      return
    }
    guard lifecycleState == .starting || lifecycleState == .running else { return }
    activeFailureHandler?(error)
    if lifecycleState == .starting {
      completePendingStart(.failure(error))
    }
    stop()
  }

  private func completePendingStart(_ result: Result<Void, any Error>) {
    let completionHandler = pendingStartCompletionHandler
    pendingStartCompletionHandler = nil
    completionHandler?(result)
  }

  private func failStart(_ error: Error) {
    guard lifecycleState == .starting else {
      completePendingStart(.failure(error))
      return
    }
    logStartFailure(error)
    let completionHandler = pendingStartCompletionHandler
    pendingStartCompletionHandler = nil
    stop {
      completionHandler?(.failure(error))
    }
  }

  private func finishEncoder(
    _ encoder: H264VideoEncoder?,
    failureHandler: (@MainActor (Error) -> Void)?,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    guard let encoder else {
      completionHandler()
      return
    }
    encoder.finish { result in
      dispatchToProgramOutputMainActor {
        if case .failure(let error) = result { failureHandler?(error) }
        completionHandler()
      }
    }
  }

  private func finishMediaBatcher(
    _ batcher: YouTubeOutputMediaBatcher?,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    guard let batcher else {
      completionHandler()
      return
    }
    batcher.finish { dispatchToProgramOutputMainActor(completionHandler) }
  }

  private func finishRecordingPipeline(
    _ pipeline: SeparatedProgramRecordingPipeline?,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    guard let pipeline else {
      completionHandler()
      return
    }
    pipeline.finish { dispatchToProgramOutputMainActor(completionHandler) }
  }

  private func stopCaptureServices(
    _ services: [CameraCaptureService],
    index: Int,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    guard index < services.count else {
      completionHandler()
      return
    }
    services[index].stop { [weak self] in
      dispatchToProgramOutputMainActor {
        self?.stopCaptureServices(
          services,
          index: index + 1,
          completionHandler: completionHandler
        )
      }
    }
  }

  private func finishSideRecorders(
    _ recorders: [AudioSideStreamRecorder],
    index: Int,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    guard index < recorders.count else {
      completionHandler()
      return
    }
    recorders[index].finish { [weak self] in
      dispatchToProgramOutputMainActor {
        self?.finishSideRecorders(
          recorders,
          index: index + 1,
          completionHandler: completionHandler
        )
      }
    }
  }

  private func completeShutdown() {
    lifecycleState = .stopped
    programOutputLogger.notice(
      "[session:\(self.id.uuidString, privacy: .public)] [event:output.stopped]"
    )
    let handlers = shutdownCompletionHandlers
    shutdownCompletionHandlers = []
    for handler in handlers {
      handler()
    }
  }

  private func performPendingRecordingSplitIfNeeded() throws {
    guard pendingRecordingSplit,
      let currentPackage = recordingPackage,
      var recordingSplitState,
      let eventHandler = activeEventHandler
    else {
      return
    }
    pendingRecordingSplit = false
    continuityState?.latestAudioInitSegments = audioSideRecordersByTrackID.reduce(into: [:]) {
      partialResult, entry in
      if let data = entry.value.cachedInitializationSegmentData() {
        partialResult[entry.key] = data
      }
    }

    let nextRecordID = Self.recordID(date: Date())
    let nextDirectory = RecordingSplitState.directoryURL(
      baseDirectory: recordingSplitState.baseDirectory,
      recordID: nextRecordID
    )
    recordingSplitState.packageConfiguration.recordID = nextRecordID
    let nextPackage = try makeRecordingPackage(
      configuration: recordingSplitState.packageConfiguration,
      directory: nextDirectory
    )
    logRecordingPackagePaths(
      package: nextPackage,
      sideRecordingTracks: recordingSplitState.packageConfiguration.audioTracks
    )
    recordingPackage = nextPackage
    self.recordingSplitState = recordingSplitState
    try recordingPipeline?.rotate(to: nextPackage)
    for (trackID, recorder) in audioSideRecordersByTrackID {
      guard let trackRecorder = nextPackage.audioTracks[trackID] else {
        continue
      }
      try recorder.rotate(to: trackRecorder)
    }
    currentPackage.finish()
    eventHandler("Recording package split: \(nextPackage.directory.path)")
  }

  private func makeRecordingPackage(
    configuration: HLSByteRangeRecordingPackageConfiguration,
    directory: URL
  ) throws -> HLSByteRangeRecordingPackage {
    guard !FileManager.default.fileExists(atPath: directory.path) else {
      throw ProgramOutputSessionError.recordingPackageAlreadyExists(directory)
    }
    var configuration = configuration
    configuration.directory = directory
    return try HLSByteRangeRecordingPackage(configuration: configuration)
  }

  private func logRecordingPackagePaths(
    package: HLSByteRangeRecordingPackage,
    sideRecordingTracks: [HLSByteRangeRecordingAudioTrack]
  ) {
    let mainStreamURL = package.directory.appendingPathComponent(
      "main-stream.mp4", isDirectory: false)
    let mainPlaylistURL = package.directory.appendingPathComponent(
      "main-stream.m3u8", isDirectory: false)
    programOutputLogger.notice(
      "[session:\(self.id.uuidString, privacy: .public)] [event:recording.package.created] directory=\(package.directory.path, privacy: .public), mainStream=\(mainStreamURL.path, privacy: .public), mainPlaylist=\(mainPlaylistURL.path, privacy: .public), audioTrackCount=\(sideRecordingTracks.count, privacy: .public)"
    )
    for track in sideRecordingTracks {
      let mediaURL = package.directory.appendingPathComponent(
        "\(track.fileNameStem).mp4", isDirectory: false)
      let playlistURL = package.directory.appendingPathComponent(
        "\(track.fileNameStem).m3u8", isDirectory: false)
      programOutputLogger.notice(
        "[session:\(self.id.uuidString, privacy: .public)] [event:recording.side-track.created] id=\(track.id, privacy: .public), displayName=\(track.displayName, privacy: .public), media=\(mediaURL.path, privacy: .public), playlist=\(playlistURL.path, privacy: .public)"
      )
    }
  }

  private func resolvedContinuityState(
    endpoint: DASHIngestEndpoint?,
    outputConfigurationFingerprint: DASHStreamOutputConfigurationFingerprint
  ) -> DASHStreamContinuityState {
    if let endpoint,
      let continuityState,
      continuityState.canResume(
        endpoint: endpoint,
        outputConfigurationFingerprint: outputConfigurationFingerprint
      )
    {
      var continuityState = continuityState
      continuityState.latestAudioInitSegments = [:]
      return continuityState
    }
    return DASHStreamContinuityState(
      endpointIdentity: endpoint?.baseURL.absoluteString,
      availabilityStartTime: Date(),
      nextMediaSegmentNumber: 1,
      latestInitSegment: nil,
      latestAudioInitSegments: [:],
      outputConfigurationFingerprint: outputConfigurationFingerprint
    )
  }

  private func startAudioSideStreams(
    plans: [AudioTrackPlan],
    index: Int,
    excludingTrackIDs: Set<String>,
    package: HLSByteRangeRecordingPackage,
    segmentDurationSeconds: Int,
    eventHandler: @escaping @MainActor (String) -> Void,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    guard lifecycleState == .starting, index < plans.count else {
      completionHandler()
      return
    }
    let plan = plans[index]
    guard !excludingTrackIDs.contains(plan.trackID),
      let trackRecorder = package.audioTracks[plan.trackID]
    else {
      startAudioSideStreams(
        plans: plans,
        index: index + 1,
        excludingTrackIDs: excludingTrackIDs,
        package: package,
        segmentDurationSeconds: segmentDurationSeconds,
        eventHandler: eventHandler,
        completionHandler: completionHandler
      )
      return
    }

    let captureService = CameraCaptureService()
    let sideRecorder: AudioSideStreamRecorder
    do {
      sideRecorder = try AudioSideStreamRecorder(
        trackRecorder: trackRecorder,
        segmentDurationSeconds: segmentDurationSeconds,
        onInitializationSegment: { [weak self] data in
          dispatchToProgramOutputMainActor { [weak self] in
            self?.continuityState?.latestAudioInitSegments[plan.trackID] = data
          }
        }
      )
    } catch {
      noteAudioSideStreamStartFailure(error, plan: plan, eventHandler: eventHandler)
      startAudioSideStreams(
        plans: plans,
        index: index + 1,
        excludingTrackIDs: excludingTrackIDs,
        package: package,
        segmentDurationSeconds: segmentDurationSeconds,
        eventHandler: eventHandler,
        completionHandler: completionHandler
      )
      return
    }

    captureService.startAudioCapture(
      audioDeviceID: plan.deviceID,
      failureHandler: { [weak self] failure in
        dispatchToProgramOutputMainActor { [weak self] in
          guard let self, self.lifecycleState == .running else { return }
          self.stop()
          self.activeFailureHandler?(failure)
        }
      },
      handler: { sampleBuffer, kind in
        guard kind == .audio else { return }
        sideRecorder.append(sampleBuffer)
      },
      completionHandler: { [weak self] result in
        dispatchToProgramOutputMainActor {
          guard let self else {
            captureService.stop {
              sideRecorder.finish {}
            }
            return
          }
          guard self.lifecycleState == .starting else {
            captureService.stop {
              sideRecorder.finish {
                dispatchToProgramOutputMainActor(completionHandler)
              }
            }
            return
          }
          if case .failure(let error) = result {
            self.noteAudioSideStreamStartFailure(error, plan: plan, eventHandler: eventHandler)
            captureService.stop {
              sideRecorder.finish {
                dispatchToProgramOutputMainActor {
                  self.startAudioSideStreams(
                    plans: plans,
                    index: index + 1,
                    excludingTrackIDs: excludingTrackIDs,
                    package: package,
                    segmentDurationSeconds: segmentDurationSeconds,
                    eventHandler: eventHandler,
                    completionHandler: completionHandler
                  )
                }
              }
            }
            return
          }
          self.audioCaptureServices.append(captureService)
          self.audioSideRecordersByTrackID[plan.trackID] = sideRecorder
          self.startAudioSideStreams(
            plans: plans,
            index: index + 1,
            excludingTrackIDs: excludingTrackIDs,
            package: package,
            segmentDurationSeconds: segmentDurationSeconds,
            eventHandler: eventHandler,
            completionHandler: completionHandler
          )
        }
      }
    )
  }

  private func noteAudioSideStreamStartFailure(
    _ error: any Error,
    plan: AudioTrackPlan,
    eventHandler: @escaping @MainActor (String) -> Void
  ) {
    let nsError = error as NSError
    programOutputLogger.error(
      "[session:\(self.id.uuidString, privacy: .public)] [event:recording.side-track.failed] key=\(plan.key, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)"
    )
    eventHandler("Audio side stream failed: \(plan.key): \(error.localizedDescription)")
  }

  private func ensureSessionIsStarting() throws {
    guard lifecycleState == .starting else {
      throw CancellationError()
    }
  }

  private func logStartFailure(_ error: any Error) {
    let nsError = error as NSError
    programOutputLogger.error(
      "[session:\(self.id.uuidString, privacy: .public)] [event:output.start.failed] errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)"
    )
  }

  private func audioTrackPlans(from audioDeviceIDsByInputKey: [String: String]) -> [AudioTrackPlan]
  {
    var usedTrackIDs: Set<String> = []
    return
      audioDeviceIDsByInputKey
      .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
      .map { key, deviceID in
        let baseTrackID = sanitizedTrackID(key)
        var trackID = baseTrackID
        var suffix = 2
        while usedTrackIDs.contains(trackID) {
          trackID = "\(baseTrackID)-\(suffix)"
          suffix += 1
        }
        usedTrackIDs.insert(trackID)
        return AudioTrackPlan(key: key, trackID: trackID, deviceID: deviceID)
      }
  }

  private func sanitizedTrackID(_ value: String) -> String {
    let scalars = value.lowercased().unicodeScalars.map { scalar -> UnicodeScalar in
      if CharacterSet.alphanumerics.contains(scalar) {
        return scalar
      }
      return "-"
    }
    let collapsed = String(String.UnicodeScalarView(scalars))
      .split(separator: "-", omittingEmptySubsequences: true)
      .joined(separator: "-")
    return collapsed.isEmpty ? "audio" : collapsed
  }

  private func videoBitRate(width: Int, height: Int, frameRate: Int) -> Int {
    if width >= 1_920 || height >= 1_080 {
      frameRate >= 60 ? 6_000_000 : 4_500_000
    } else {
      frameRate >= 60 ? 4_000_000 : 2_500_000
    }
  }

  private func dashRepresentation(
    width: Int,
    height: Int,
    frameRate: Int,
    videoBitRate: Int
  ) -> DASHRepresentation {
    DASHRepresentation(
      id: "\(height)p\(frameRate)",
      bandwidth: videoBitRate + 128_000,
      width: width,
      height: height,
      frameRate: "\(frameRate)",
      codecs: "avc1.64002a,mp4a.40.2"
    )
  }

  private static func recordID(date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.remove(.withDashSeparatorInDate)
    formatter.formatOptions.remove(.withColonSeparatorInTime)
    formatter.formatOptions.remove(.withTimeZone)
    formatter.timeZone = .current
    return "LDTX\(formatter.string(from: date))"
  }
}

private final class ProgramOutputVideoFrameSink {
  private let outputSessionID: UUID
  private let encoder: H264VideoEncoder
  private let audioRenderer: ProgramAudioMonitor
  private let videoPTSSourceKey: String?
  private var lastVideoPresentationTime: CMTime?
  private var droppedNonMonotonicVideoFrameCount = 0
  private var droppedMissingVideoPTSFrameCount = 0

  init(
    outputSessionID: UUID,
    encoder: H264VideoEncoder,
    audioRenderer: ProgramAudioMonitor,
    videoPTSSourceKey: String?
  ) {
    self.outputSessionID = outputSessionID
    self.encoder = encoder
    self.audioRenderer = audioRenderer
    self.videoPTSSourceKey = videoPTSSourceKey
  }

  func consume(_ frame: ProgramFrame) {
    guard let presentationTime = frame.presentationTime else {
      droppedMissingVideoPTSFrameCount += 1
      if droppedMissingVideoPTSFrameCount == 1
        || droppedMissingVideoPTSFrameCount.isMultiple(of: 120)
      {
        programOutputLogger.error(
          "[session:\(self.outputSessionID.uuidString, privacy: .public)] [event:output.frame.missing-pts] droppedMissingVideoPTSFrameCount=\(self.droppedMissingVideoPTSFrameCount, privacy: .public) frameID=\(frame.frameID, privacy: .public) videoPTSSource=\(self.videoPTSSourceKey ?? "nil", privacy: .public)"
        )
      }
      return
    }
    if let lastVideoPresentationTime,
      CMTimeCompare(presentationTime, lastVideoPresentationTime) <= 0
    {
      droppedNonMonotonicVideoFrameCount += 1
      if droppedNonMonotonicVideoFrameCount == 1
        || droppedNonMonotonicVideoFrameCount.isMultiple(of: 120)
      {
        programOutputLogger.error(
          "[session:\(self.outputSessionID.uuidString, privacy: .public)] [event:output.frame.non-monotonic-pts] droppedNonMonotonicVideoFrameCount=\(self.droppedNonMonotonicVideoFrameCount, privacy: .public) frameID=\(frame.frameID, privacy: .public) ptsValue=\(presentationTime.value, privacy: .public) ptsTimescale=\(presentationTime.timescale, privacy: .public) lastPTSValue=\(lastVideoPresentationTime.value, privacy: .public) lastPTSTimescale=\(lastVideoPresentationTime.timescale, privacy: .public)"
        )
      }
      return
    }
    lastVideoPresentationTime = presentationTime
    audioRenderer.noteVideoPresentationTime(presentationTime)
    encoder.encode(
      pixelBuffer: frame.pixelBuffer,
      presentationTime: presentationTime,
      duration: .invalid
    )
  }
}

protocol ProgramEncodedVideoConsumer: Sendable {
  func appendVideo(_ sampleBuffer: CMSampleBuffer)
}

extension SeparatedProgramRecordingPipeline: ProgramEncodedVideoConsumer {}
extension YouTubeOutputMediaBatcher: ProgramEncodedVideoConsumer {}

final class ProgramEncodedVideoFanout: @unchecked Sendable {
  private let lock = NSLock()
  private let failureHandler: @Sendable (Error) -> Void
  var recordingPipeline: (any ProgramEncodedVideoConsumer)? {
    get { lock.withLock { storedRecordingPipeline } }
    set { lock.withLock { storedRecordingPipeline = newValue } }
  }
  var mediaBatcher: (any ProgramEncodedVideoConsumer)? {
    get { lock.withLock { storedMediaBatcher } }
    set { lock.withLock { storedMediaBatcher = newValue } }
  }
  private var storedRecordingPipeline: (any ProgramEncodedVideoConsumer)?
  private var storedMediaBatcher: (any ProgramEncodedVideoConsumer)?

  init(failureHandler: @escaping @Sendable (Error) -> Void) {
    self.failureHandler = failureHandler
  }

  func receive(_ result: Result<CMSampleBuffer, any Error>) {
    switch result {
    case .success(let sampleBuffer):
      let targets = lock.withLock { (storedRecordingPipeline, storedMediaBatcher) }
      targets.0?.appendVideo(sampleBuffer)
      targets.1?.appendVideo(sampleBuffer)
    case .failure(let error): failureHandler(error)
    }
  }
}

private final class ProgramYouTubeOutputReadyRelay: @unchecked Sendable {
  private let lock = NSLock()
  private weak var storedEncoder: H264VideoEncoder?
  private var hasPendingRequest = false
  var encoder: H264VideoEncoder? {
    get { lock.withLock { storedEncoder } }
    set {
      let shouldRequest = lock.withLock {
        storedEncoder = newValue
        defer { hasPendingRequest = false }
        return hasPendingRequest
      }
      if shouldRequest { newValue?.requestKeyFrame() }
    }
  }
  func requestKeyFrame() {
    let encoder: H264VideoEncoder? = lock.withLock {
      guard let storedEncoder else {
        hasPendingRequest = true
        return nil
      }
      return storedEncoder
    }
    encoder?.requestKeyFrame()
  }
}
