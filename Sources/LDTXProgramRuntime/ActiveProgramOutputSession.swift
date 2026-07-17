// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXDash
import LDTXMP4
import LDTXProgram
import LDTXRecording
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

public enum ActiveProgramOutputSessionError: Error, LocalizedError {
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

public protocol ErrorDialogPresentable: Error {
  var errorDialogKind: ErrorDialogKind { get }
}

public enum ErrorDialogKind: String, Identifiable, Sendable {
  case recordingAudioTrackUnavailable
  case recordingWriterFailed
  case recordingFinalizationFailed

  public var id: String { rawValue }
}

public enum ProgramOutputFlowInterruptionError: Error, LocalizedError,
  ErrorDialogPresentable
{
  case recordingAudioTrackUnavailable(String)
  case recordingWriterFailed(String)
  case recordingFinalizationFailed(String)

  public var errorDialogKind: ErrorDialogKind {
    switch self {
    case .recordingAudioTrackUnavailable:
      .recordingAudioTrackUnavailable
    case .recordingWriterFailed:
      .recordingWriterFailed
    case .recordingFinalizationFailed:
      .recordingFinalizationFailed
    }
  }

  public var errorDescription: String? {
    switch self {
    case .recordingAudioTrackUnavailable(let name):
      "The recording audio track could not be started: \(name)"
    case .recordingWriterFailed(let reason):
      "The recording writer failed: \(reason)"
    case .recordingFinalizationFailed(let reason):
      "The recording could not be finalized: \(reason)"
    }
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
public final class ActiveProgramOutputSession {
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
    var deviceName: String
    var fileNameStem: String
  }

  public let id: UUID
  private let activeProgramRuntime: ActiveProgramRuntime
  private let continuityStore: ProgramDASHStreamContinuityStore
  private let youtubeOutputBoundary: ProgramYouTubeOutputBoundary?
  private var shutdownCompletionHandlers: [@MainActor @Sendable () -> Void] = []
  private var frameStreamID: UUID?
  private var uploadPipeline: ProgramYouTubeOutputXPCSink?
  private var videoEncoder: H264VideoEncoder?
  private var videoFanout: ProgramEncodedVideoFanout?
  private var mediaBatcher: YouTubeOutputMediaBatcher?
  private var recordingPipeline: SeparatedProgramRecordingPipeline?
  private var recordingTimelineNormalizer: RecordingTimelineNormalizer?
  private var audioOutputSampleHandlerID: UUID?
  private var recordingPackage: HLSByteRangeRecordingPackage?
  private var audioRenderer: ProgramAudioMonitor?
  private var audioInputSampleHandlerIDs: [UUID] = []
  private var audioSideRecordersByTrackID: [String: AudioSideStreamRecorder] = [:]
  private var activeEventHandler: (@MainActor (String) -> Void)?
  private var activeFailureHandler: (@MainActor (Error) -> Void)?
  private var pendingStartCompletionHandler:
    (@MainActor @Sendable (Result<Void, any Error>) -> Void)?
  private var lifecycleState: LifecycleState = .idle
  private var continuityEndpointIdentity: String?

  public init(
    id: UUID = UUID(),
    activeProgramRuntime: ActiveProgramRuntime,
    continuityStore: ProgramDASHStreamContinuityStore = ProgramDASHStreamContinuityStore(),
    youtubeOutputBoundary: ProgramYouTubeOutputBoundary? = nil
  ) {
    self.id = id
    self.activeProgramRuntime = activeProgramRuntime
    self.continuityStore = continuityStore
    self.youtubeOutputBoundary = youtubeOutputBoundary
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

  public func start(
    snapshot: ProgramPreviewSnapshot,
    endpoint: DASHIngestEndpoint?,
    recordingBaseDirectory: URL?,
    programPreferences: ProgramPreferences,
    audioDeviceIDsByInputKey: [String: String],
    audioDeviceNamesByInputKey: [String: String],
    audioRenderer: ProgramAudioMonitor,
    eventHandler: @escaping @MainActor (String) -> Void,
    failureHandler: @escaping @MainActor (Error) -> Void,
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard lifecycleState == .idle else {
      programOutputLogger.error(
        "[session:\(self.id.uuidString, privacy: .public)] [event:output.start.rejected] reason=session-already-used"
      )
      completionHandler(.failure(ActiveProgramOutputSessionError.sessionAlreadyUsed))
      return
    }
    lifecycleState = .starting
    pendingStartCompletionHandler = completionHandler
    continuityEndpointIdentity = endpoint?.baseURL.absoluteString

    do {

      let frameRate = max(snapshot.frameRate, 1)
      let audioTrackPlans = audioTrackPlans(
        from: audioDeviceIDsByInputKey,
        namesByInputKey: audioDeviceNamesByInputKey
      )
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
      activeEventHandler = eventHandler
      activeFailureHandler = failureHandler

      let serviceReadyRelay = ProgramYouTubeOutputReadyRelay()
      youtubeOutputBoundary?.attach(
        eventHandler: eventHandler,
        failureHandler: { [weak self] error in self?.handleYouTubeOutputFailure(error) },
        checkpointHandler: { [weak self] checkpoint in
          self?.applyYouTubeOutputCheckpoint(checkpoint)
        },
        readyHandler: { serviceReadyRelay.requestKeyFrame() }
      )
      let outputBoundary = youtubeOutputBoundary
      let pipeline: ProgramYouTubeOutputXPCSink?
      if let endpoint {
        if let existing = outputBoundary?.sink {
          pipeline = existing
        } else {
          let newSink = ProgramYouTubeOutputXPCSink(
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
              dispatchToProgramOutputMainActor { [weak outputBoundary] in
                if let outputBoundary {
                  outputBoundary.receiveEvent(message)
                } else {
                  eventHandler(message)
                }
              }
            },
            failureHandler: { error in
              dispatchToProgramOutputMainActor { [weak self, weak outputBoundary] in
                if let outputBoundary {
                  outputBoundary.receiveFailure(error)
                } else {
                  self?.handleYouTubeOutputFailure(error)
                }
              }
            },
            readyHandler: {
              dispatchToProgramOutputMainActor { [weak outputBoundary] in
                if let outputBoundary {
                  outputBoundary.becomeReady()
                } else {
                  serviceReadyRelay.requestKeyFrame()
                }
              }
            },
            checkpointHandler: { [weak self, weak outputBoundary] checkpoint in
              dispatchToProgramOutputMainActor {
                if let outputBoundary {
                  outputBoundary.receiveCheckpoint(checkpoint)
                } else {
                  self?.applyYouTubeOutputCheckpoint(checkpoint)
                }
              }
            }
          )
          outputBoundary?.install(newSink)
          pipeline = newSink
        }
      } else {
        pipeline = nil
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
        let sideRecordingTracks = audioTrackPlans.map { plan in
          return HLSByteRangeRecordingAudioTrack(
            id: plan.trackID,
            displayName: plan.deviceName,
            fileNameStem: plan.fileNameStem
          )
        }
        let recordingAudioTracks =
          [
            HLSByteRangeRecordingAudioTrack(
              id: SeparatedProgramRecordingPipeline.mainAudioTrackID,
              displayName: "Main Mix",
              fileNameStem: "output-audio"
            )
          ] + sideRecordingTracks
        let packageConfiguration = HLSByteRangeRecordingPackageConfiguration(
          directory: Self.recordingDirectoryURL(
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
        let package = try makeRecordingPackage(
          configuration: packageConfiguration,
          directory: packageConfiguration.directory
        )
        recordingPackage = package
        let recordingTimelineNormalizer = RecordingTimelineNormalizer()
        self.recordingTimelineNormalizer = recordingTimelineNormalizer
        let recordingPipeline = try SeparatedProgramRecordingPipeline(
          package: package,
          segmentDurationSeconds: writerConfiguration.segmentDurationSeconds,
          startNumber: writerConfiguration.startNumber,
          timelineNormalizer: recordingTimelineNormalizer,
          failureHandler: { error in
            dispatchToProgramOutputMainActor { [weak self] in
              self?.handleOutputFailure(
                ProgramOutputFlowInterruptionError.recordingWriterFailed(
                  error.localizedDescription
                ))
            }
          }
        )
        self.recordingPipeline = recordingPipeline
        fanout.recordingPipeline = recordingPipeline
        logRecordingPackagePaths(package: package, sideRecordingTracks: sideRecordingTracks)
        try startAudioSideStreams(
          plans: audioTrackPlans,
          package: package,
          segmentDurationSeconds: writerConfiguration.segmentDurationSeconds,
          timelineNormalizer: recordingTimelineNormalizer,
          audioRenderer: audioRenderer,
          eventHandler: eventHandler
        )
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
        return
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
      audioRenderer: audioRenderer
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
      initializationSegment: continuityState.latestInitSegment,
      persistenceIdentifier: endpoint.baseURL.absoluteString
    )
  }

  private func applyYouTubeOutputCheckpoint(_ checkpoint: YouTubeOutputCheckpoint) {
    guard var state = continuityState, state.apply(checkpoint) else { return }
    continuityState = state
  }

  private func handleYouTubeOutputFailure(_ error: Error) {
    if let error = error as? OutputXPCError, error.requiresGlobalStop {
      handleOutputFailure(
        ActiveProgramOutputSessionError.outputServiceRecoveryExhausted(
          error.localizedDescription
        ))
    } else {
      handleOutputFailure(error)
    }
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
    for id in audioInputSampleHandlerIDs {
      audioRenderer?.removeInputSampleHandler(id: id)
    }
    let audioSideRecordersByTrackID = audioSideRecordersByTrackID
    let recordingPackage = recordingPackage
    let failureHandler = activeFailureHandler
    recordingTimelineNormalizer?.finish()

    finishSideRecorders(
      Array(audioSideRecordersByTrackID.values),
      index: 0
    ) { [weak self] in
      self?.finishEncoder(videoEncoder, failureHandler: failureHandler) { [weak self] in
        self?.finishMediaBatcher(mediaBatcher) { [weak self] in
          self?.finishRecordingPipeline(recordingPipeline) { [weak self] in
            guard let uploadPipeline, self?.youtubeOutputBoundary == nil else {
              self?.finishRecordingPackage(
                recordingPackage,
                failureHandler: failureHandler
              )
              self?.completeShutdown()
              return
            }
            uploadPipeline.finish {
              dispatchToProgramOutputMainActor {
                self?.finishRecordingPackage(
                  recordingPackage,
                  failureHandler: failureHandler
                )
                self?.completeShutdown()
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

  private func finishRecordingPackage(
    _ package: HLSByteRangeRecordingPackage?,
    failureHandler: (@MainActor (Error) -> Void)?
  ) {
    guard let package else { return }
    do {
      try package.finish()
    } catch {
      let nsError = error as NSError
      programOutputLogger.error(
        "[session:\(self.id.uuidString, privacy: .public)] [event:recording.package.finalize.failed] errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)"
      )
      failureHandler?(
        ProgramOutputFlowInterruptionError.recordingFinalizationFailed(
          error.localizedDescription
        ))
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

  private func makeRecordingPackage(
    configuration: HLSByteRangeRecordingPackageConfiguration,
    directory: URL
  ) throws -> HLSByteRangeRecordingPackage {
    guard !FileManager.default.fileExists(atPath: directory.path) else {
      throw ActiveProgramOutputSessionError.recordingPackageAlreadyExists(directory)
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
      "output-video.mp4", isDirectory: false)
    let manifestURL = package.directory.appendingPathComponent(
      RecordingPackage.manifestFileName, isDirectory: false)
    programOutputLogger.notice(
      "[session:\(self.id.uuidString, privacy: .public)] [event:recording.package.created] directory=\(package.directory.path, privacy: .public), mainStream=\(mainStreamURL.path, privacy: .public), manifest=\(manifestURL.path, privacy: .public), audioTrackCount=\(sideRecordingTracks.count, privacy: .public)"
    )
    for track in sideRecordingTracks {
      let mediaURL = package.directory.appendingPathComponent(
        "\(track.fileNameStem).mp4", isDirectory: false)
      programOutputLogger.notice(
        "[session:\(self.id.uuidString, privacy: .public)] [event:recording.side-track.created] id=\(track.id, privacy: .public), displayName=\(track.displayName, privacy: .public), media=\(mediaURL.path, privacy: .public)"
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
    package: HLSByteRangeRecordingPackage,
    segmentDurationSeconds: Int,
    timelineNormalizer: RecordingTimelineNormalizer,
    audioRenderer: ProgramAudioMonitor,
    eventHandler: @escaping @MainActor (String) -> Void
  ) throws {
    for plan in plans {
      guard let trackRecorder = package.audioTracks[plan.trackID] else { continue }
      let sideRecorder: AudioSideStreamRecorder
      do {
        sideRecorder = try AudioSideStreamRecorder(
          trackRecorder: trackRecorder,
          segmentDurationSeconds: segmentDurationSeconds,
          timelineNormalizer: timelineNormalizer,
          timelineTrackID: plan.trackID,
          onInitializationSegment: { [weak self] data in
            dispatchToProgramOutputMainActor { [weak self] in
              self?.continuityState?.latestAudioInitSegments[plan.trackID] = data
            }
          }
        )
      } catch {
        noteAudioSideStreamStartFailure(error, plan: plan, eventHandler: eventHandler)
        throw ProgramOutputFlowInterruptionError.recordingAudioTrackUnavailable(plan.deviceName)
      }
      let handlerID = audioRenderer.addInputSampleHandler(
        forChannelKey: plan.key,
        { sideRecorder.append($0) }
      )
      audioInputSampleHandlerIDs.append(handlerID)
      audioSideRecordersByTrackID[plan.trackID] = sideRecorder
    }
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

  private func audioTrackPlans(
    from audioDeviceIDsByInputKey: [String: String],
    namesByInputKey: [String: String]
  ) -> [AudioTrackPlan] {
    var usedTrackIDs: Set<String> = []
    var usedFileNameStems: Set<String> = []
    return
      audioDeviceIDsByInputKey
      .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
      .map { key, _ in
        let baseTrackID = sanitizedTrackID(key)
        var trackID = baseTrackID
        var suffix = 2
        while usedTrackIDs.contains(trackID) {
          trackID = "\(baseTrackID)-\(suffix)"
          suffix += 1
        }
        usedTrackIDs.insert(trackID)
        let deviceName = namesByInputKey[key] ?? key
        let encodedName = percentEncodedFileName(deviceName)
        var fileNameStem = "InputDevices/\(encodedName)"
        var fileNameSuffix = 2
        while usedFileNameStems.contains(fileNameStem) {
          fileNameStem = "InputDevices/\(encodedName)~\(fileNameSuffix)"
          fileNameSuffix += 1
        }
        usedFileNameStems.insert(fileNameStem)
        return AudioTrackPlan(
          key: key,
          trackID: trackID,
          deviceName: deviceName,
          fileNameStem: fileNameStem
        )
      }
  }

  private func percentEncodedFileName(_ value: String) -> String {
    let encoded = value.utf8.map { byte -> String in
      switch byte {
      case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
        String(UnicodeScalar(byte))
      default:
        String(format: "%%%02X", byte)
      }
    }.joined()
    return encoded.isEmpty ? "Audio" : encoded
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
    formatter.formatOptions.insert(.withFractionalSeconds)
    formatter.formatOptions.remove(.withDashSeparatorInDate)
    formatter.formatOptions.remove(.withColonSeparatorInTime)
    formatter.formatOptions.remove(.withTimeZone)
    formatter.timeZone = .current
    return "LDTX\(formatter.string(from: date))"
  }

  private static func recordingDirectoryURL(
    baseDirectory: URL,
    recordID: String
  ) -> URL {
    baseDirectory
      .appendingPathComponent(recordID, isDirectory: true)
      .appendingPathExtension(RecordingPackage.pathExtension)
  }
}

private final class ProgramOutputVideoFrameSink {
  private let outputSessionID: UUID
  private let encoder: H264VideoEncoder
  private let audioRenderer: ProgramAudioMonitor
  private var lastVideoPresentationTime: CMTime?
  private var droppedNonMonotonicVideoFrameCount = 0

  init(
    outputSessionID: UUID,
    encoder: H264VideoEncoder,
    audioRenderer: ProgramAudioMonitor
  ) {
    self.outputSessionID = outputSessionID
    self.encoder = encoder
    self.audioRenderer = audioRenderer
  }

  func consume(_ frame: ProgramFrame) {
    guard let presentationTime = frame.presentationTime else {
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
