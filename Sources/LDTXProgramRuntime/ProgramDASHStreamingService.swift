// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXCapture
import LDTXDash
import LDTXMP4
import LDTXProgram
import OSLog

private let programDASHStreamingLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "ProgramDASHStreamingSession"
)

private func dispatchToProgramDASHMainActor(
    _ operation: @escaping @MainActor @Sendable () -> Void
) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            operation()
        }
    }
}

public enum ProgramDASHStreamingSessionError: Error, LocalizedError {
    case sessionAlreadyUsed

    public var errorDescription: String? {
        switch self {
        case .sessionAlreadyUsed:
            "An output session can only be started once. Create a new session for each output."
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
public final class ProgramDASHStreamingSession {
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

    private let activeProgramRuntime: ActiveProgramRuntime
    private let continuityStore: ProgramDASHStreamContinuityStore
    private var shutdownCompletionHandlers: [@MainActor @Sendable () -> Void] = []
    private var frameStreamID: UUID?
    private var uploadPipeline: DASHLiveUploadPipeline?
    private var pendingSegments: [SegmentedMP4Segment] = []
    private var isProcessingSegment = false
    private var segmentDrainCompletionHandlers: [@MainActor @Sendable () -> Void] = []
    private var writer: SegmentedMP4Writer?
    private var recordingPackage: HLSByteRangeRecordingPackage?
    private var recordingSplitState: RecordingSplitState?
    private var audioRenderer: ProgramAudioMonitor?
    private var audioCaptureServices: [CameraCaptureService] = []
    private var audioSideRecordersByTrackID: [String: AudioSideStreamRecorder] = [:]
    private var activeEventHandler: (@MainActor (String) -> Void)?
    private var activeFailureHandler: (@MainActor (Error) -> Void)?
    private var pendingRecordingSplit = false
    private var lifecycleState: LifecycleState = .idle
    private var continuityEndpointIdentity: String?

    public init(
        activeProgramRuntime: ActiveProgramRuntime,
        continuityStore: ProgramDASHStreamContinuityStore = ProgramDASHStreamContinuityStore()
    ) {
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
        programArguments: ProgramArguments,
        audioDeviceIDsByInputKey: [String: String],
        audioRenderer: ProgramAudioMonitor,
        eventHandler: @escaping @MainActor (String) -> Void,
        failureHandler: @escaping @MainActor (Error) -> Void,
        completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
    ) {
        guard lifecycleState == .idle else {
            completionHandler(.failure(ProgramDASHStreamingSessionError.sessionAlreadyUsed))
            return
        }
        lifecycleState = .starting
        continuityEndpointIdentity = endpoint?.baseURL.absoluteString

        do {

        let frameRate = max(snapshot.frameRate, 1)
        let audioTrackPlans = audioTrackPlans(from: audioDeviceIDsByInputKey)
        let baseWriterConfiguration = SegmentedMP4WriterConfiguration(
            width: snapshot.outputWidth,
            height: snapshot.outputHeight,
            frameRate: frameRate,
            videoBitRate: videoBitRate(width: snapshot.outputWidth, height: snapshot.outputHeight, frameRate: frameRate)
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
            videoPixelBufferPoolMinimumBufferCount: baseWriterConfiguration.videoPixelBufferPoolMinimumBufferCount,
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

        let pipeline: DASHLiveUploadPipeline? = if let endpoint {
            DASHLiveUploadPipeline(
                endpoint: endpoint,
                manifestConfiguration: DASHManifestConfiguration(
                    availabilityStartTime: continuityState.availabilityStartTime,
                    timescale: writerConfiguration.timescale,
                    segmentDurationSeconds: writerConfiguration.segmentDurationSeconds,
                    startNumber: writerConfiguration.startNumber,
                    mediaTemplate: endpoint.mpdReference(for: "media$Number%09d$.mp4"),
                    initialization: .embedded(data: continuityState.latestInitSegment ?? Data()),
                    representation: dashRepresentation(
                        width: snapshot.outputWidth,
                        height: snapshot.outputHeight,
                        frameRate: frameRate,
                        videoBitRate: writerConfiguration.videoBitRate
                    )
                )
            )
        } else {
            nil
        }
        uploadPipeline = pipeline
        let writer = try SegmentedMP4Writer(configuration: writerConfiguration) { [weak self] segment in
            DispatchQueue.main.async {
                self?.enqueueSegment(segment)
            }
        }
        self.writer = writer
        self.audioRenderer = audioRenderer
        audioRenderer.attach(writer: writer)
        audioRenderer.updateGains(audioChannels: snapshot.audioChannels, arguments: programArguments)
        programDASHStreamingLogger.notice(
            "Starting output session: videoPTSSource=\(snapshot.programVideoPTSInputKey ?? "host-clock", privacy: .public), audioDriver=independent-pull, audioTiming=absolute-deadline-200ms, audioChannelCount=\(snapshot.audioChannels.count, privacy: .public)"
        )

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
            let initialSplitState = RecordingSplitState(
                baseDirectory: recordingBaseDirectory,
                recordID: recordID,
                nextPartIndex: 2,
                packageConfiguration: HLSByteRangeRecordingPackageConfiguration(
                    directory: RecordingSplitState.directoryURL(
                        baseDirectory: recordingBaseDirectory,
                        recordID: recordID,
                        partIndex: 1
                    ),
                    recordID: recordID,
                    targetDurationSeconds: writerConfiguration.segmentDurationSeconds,
                    videoCodecs: "avc1.64002a",
                    audioCodecs: "mp4a.40.2",
                    bandwidth: writerConfiguration.videoBitRate + writerConfiguration.audioBitRate,
                    includesMainAudioTrack: true,
                    audioTracks: sideRecordingTracks
                )
            )
            let package = try makeRecordingPackage(
                configuration: initialSplitState.packageConfiguration,
                directory: initialSplitState.initialDirectory
            )
            recordingPackage = package
            recordingSplitState = initialSplitState
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
                        writer: writer,
                        snapshot: snapshot,
                        frameRate: frameRate,
                        audioRenderer: audioRenderer,
                        eventHandler: eventHandler,
                        failureHandler: failureHandler,
                        completionHandler: completionHandler
                    )
                } catch {
                    lifecycleState = .stopped
                    completionHandler(.failure(error))
                }
            }
            return
        } else {
            recordingSplitState = nil
        }

        completeStart(
            writer: writer,
            snapshot: snapshot,
            frameRate: frameRate,
            audioRenderer: audioRenderer,
            eventHandler: eventHandler,
            failureHandler: failureHandler,
            completionHandler: completionHandler
        )
        } catch {
            lifecycleState = .stopped
            completionHandler(.failure(error))
        }
    }

    private func completeStart(
        writer: SegmentedMP4Writer,
        snapshot: ProgramPreviewSnapshot,
        frameRate: Int,
        audioRenderer: ProgramAudioMonitor,
        eventHandler: @escaping @MainActor (String) -> Void,
        failureHandler: @escaping @MainActor (Error) -> Void,
        completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
    ) {
        activeProgramRuntime.beginOutput(snapshot: snapshot)
        let frameSink = ProgramDASHVideoFrameSink(
            writer: writer,
            audioRenderer: audioRenderer,
            videoPTSSourceKey: snapshot.programVideoPTSInputKey
        )
        self.frameStreamID = activeProgramRuntime.addFrameHandler { frame in
            frameSink.consume(frame)
        }
        do {
            try ensureSessionIsStarting()
            lifecycleState = .running
            completionHandler(.success(()))
        } catch {
            lifecycleState = .stopped
            completionHandler(.failure(error))
        }
    }

    private func enqueueSegment(_ segment: SegmentedMP4Segment) {
        guard lifecycleState == .starting || lifecycleState == .running || lifecycleState == .stopping else {
            return
        }
        pendingSegments.append(segment)
        processNextSegmentIfNeeded()
    }

    private func processNextSegmentIfNeeded() {
        guard !isProcessingSegment else {
            return
        }
        guard !pendingSegments.isEmpty else {
            let handlers = segmentDrainCompletionHandlers
            segmentDrainCompletionHandlers = []
            handlers.forEach { $0() }
            return
        }
        isProcessingSegment = true
        let segment = pendingSegments.removeFirst()
        noteMainSegment(segment)
        do {
            try recordingPackage?.mainTrack.write(segment)
        } catch {
            failSegmentProcessing(error)
            return
        }

        guard let uploadPipeline else {
            completeSegmentProcessing(segment, event: nil)
            return
        }
        uploadPipeline.upload(segment) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                switch result {
                case let .success(event):
                    self.completeSegmentProcessing(segment, event: event)
                case let .failure(error):
                    self.failSegmentProcessing(error)
                }
            }
        }
    }

    private func completeSegmentProcessing(
        _ segment: SegmentedMP4Segment,
        event: DASHLiveUploadPipelineEvent?
    ) {
        if let event {
            let description = Self.eventDescription(event)
            programDASHStreamingLogger.notice("\(description, privacy: .public)")
            activeEventHandler?(description)
        }
        do {
            if case .media = segment.kind {
                try performPendingRecordingSplitIfNeeded()
            }
        } catch {
            failSegmentProcessing(error)
            return
        }
        isProcessingSegment = false
        processNextSegmentIfNeeded()
    }

    private func failSegmentProcessing(_ error: any Error) {
        let nsError = error as NSError
        programDASHStreamingLogger.error(
            "Output segment processing failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)"
        )
        pendingSegments = []
        isProcessingSegment = false
        activeFailureHandler?(error)
        stop()
    }

    private func finishSegmentProcessing(
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        guard isProcessingSegment || !pendingSegments.isEmpty else {
            completionHandler()
            return
        }
        segmentDrainCompletionHandlers.append(completionHandler)
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
        lifecycleState = .stopping
        shutdownCompletionHandlers.append(completionHandler)

        if let frameStreamID {
            activeProgramRuntime.removeFrameHandler(id: frameStreamID)
        }
        activeProgramRuntime.endOutput()

        let writer = writer
        audioRenderer?.detachWriter()
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
                self?.finishWriter(
                    writer,
                    failureHandler: failureHandler
                ) { [weak self] in
                    self?.finishSegmentProcessing { [weak self] in
                        recordingPackage?.finish()
                        self?.completeShutdown()
                    }
                }
            }
        }
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
            dispatchToProgramDASHMainActor {
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
            dispatchToProgramDASHMainActor {
                self?.finishSideRecorders(
                    recorders,
                    index: index + 1,
                    completionHandler: completionHandler
                )
            }
        }
    }

    private func finishWriter(
        _ writer: SegmentedMP4Writer?,
        failureHandler: (@MainActor (Error) -> Void)?,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let writer else {
            completionHandler()
            return
        }
        writer.finish { result in
            dispatchToProgramDASHMainActor {
                if case let .failure(error) = result {
                    let nsError = error as NSError
                    programDASHStreamingLogger.error("Segmented MP4 writer finish failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)")
                    failureHandler?(error)
                }
                completionHandler()
            }
        }
    }

    private func completeShutdown() {
        lifecycleState = .stopped
        let handlers = shutdownCompletionHandlers
        shutdownCompletionHandlers = []
        for handler in handlers {
            handler()
        }
    }

    private func noteMainSegment(_ segment: SegmentedMP4Segment) {
        continuityState?.noteMainSegment(segment)
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
        continuityState?.latestAudioInitSegments = audioSideRecordersByTrackID.reduce(into: [:]) { partialResult, entry in
            if let data = entry.value.cachedInitializationSegmentData() {
                partialResult[entry.key] = data
            }
        }

        let nextDirectory = recordingSplitState.nextDirectory()
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
        if let latestInitSegment = continuityState?.latestInitSegment {
            try nextPackage.mainTrack.write(
                SegmentedMP4Segment(kind: .initialization, data: latestInitSegment)
            )
        }
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
        var configuration = configuration
        configuration.directory = directory
        return try HLSByteRangeRecordingPackage(configuration: configuration)
    }

    private func logRecordingPackagePaths(
        package: HLSByteRangeRecordingPackage,
        sideRecordingTracks: [HLSByteRangeRecordingAudioTrack]
    ) {
        let mainStreamURL = package.directory.appendingPathComponent("main-stream.mp4", isDirectory: false)
        let mainPlaylistURL = package.directory.appendingPathComponent("main-stream.m3u8", isDirectory: false)
        programDASHStreamingLogger.notice(
            "Recording package paths: directory=\(package.directory.path, privacy: .public), mainStream=\(mainStreamURL.path, privacy: .public), mainPlaylist=\(mainPlaylistURL.path, privacy: .public), audioTrackCount=\(sideRecordingTracks.count, privacy: .public)"
        )
        for track in sideRecordingTracks {
            let mediaURL = package.directory.appendingPathComponent("\(track.fileNameStem).mp4", isDirectory: false)
            let playlistURL = package.directory.appendingPathComponent("\(track.fileNameStem).m3u8", isDirectory: false)
            programDASHStreamingLogger.notice(
                "Recording side track path: id=\(track.id, privacy: .public), displayName=\(track.displayName, privacy: .public), media=\(mediaURL.path, privacy: .public), playlist=\(playlistURL.path, privacy: .public)"
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
           ) {
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
              let trackRecorder = package.audioTracks[plan.trackID] else {
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
                    dispatchToProgramDASHMainActor { [weak self] in
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
                dispatchToProgramDASHMainActor { [weak self] in
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
                dispatchToProgramDASHMainActor {
                    guard let self else {
                        captureService.stop {
                            sideRecorder.finish {}
                        }
                        return
                    }
                    guard self.lifecycleState == .starting else {
                        captureService.stop {
                            sideRecorder.finish {
                                dispatchToProgramDASHMainActor(completionHandler)
                            }
                        }
                        return
                    }
                    if case let .failure(error) = result {
                        self.noteAudioSideStreamStartFailure(error, plan: plan, eventHandler: eventHandler)
                        captureService.stop {
                            sideRecorder.finish {
                                dispatchToProgramDASHMainActor {
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
        programDASHStreamingLogger.error("Audio side stream failed key=\(plan.key, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)")
        eventHandler("Audio side stream failed: \(plan.key): \(error.localizedDescription)")
    }

    private func ensureSessionIsStarting() throws {
        guard lifecycleState == .starting else {
            throw CancellationError()
        }
    }

    private func audioTrackPlans(from audioDeviceIDsByInputKey: [String: String]) -> [AudioTrackPlan] {
        var usedTrackIDs: Set<String> = []
        return audioDeviceIDsByInputKey
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

    private static func eventDescription(_ event: DASHLiveUploadPipelineEvent) -> String {
        switch event {
        case let .manifestUploaded(byteCount):
            "DASH manifest uploaded (\(byteCount) bytes)."
        case let .mediaSegmentUploaded(number, byteCount):
            "DASH media segment \(number) uploaded (\(byteCount) bytes)."
        }
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

private final class ProgramDASHVideoFrameSink {
    private let writer: SegmentedMP4Writer
    private let audioRenderer: ProgramAudioMonitor
    private let videoPTSSourceKey: String?
    private var lastVideoPresentationTime: CMTime?
    private var droppedNonMonotonicVideoFrameCount = 0
    private var droppedMissingVideoPTSFrameCount = 0

    init(
        writer: SegmentedMP4Writer,
        audioRenderer: ProgramAudioMonitor,
        videoPTSSourceKey: String?
    ) {
        self.writer = writer
        self.audioRenderer = audioRenderer
        self.videoPTSSourceKey = videoPTSSourceKey
    }

    func consume(_ frame: ProgramFrame) {
        guard let presentationTime = frame.presentationTime else {
            droppedMissingVideoPTSFrameCount += 1
            if droppedMissingVideoPTSFrameCount == 1 ||
                droppedMissingVideoPTSFrameCount.isMultiple(of: 120) {
                programDASHStreamingLogger.error(
                    "Program output skipped frame without shared video pts droppedMissingVideoPTSFrameCount=\(self.droppedMissingVideoPTSFrameCount, privacy: .public) frameID=\(frame.frameID, privacy: .public) videoPTSSource=\(self.videoPTSSourceKey ?? "nil", privacy: .public)"
                )
            }
            return
        }
        if let lastVideoPresentationTime,
           CMTimeCompare(presentationTime, lastVideoPresentationTime) <= 0 {
            droppedNonMonotonicVideoFrameCount += 1
            if droppedNonMonotonicVideoFrameCount == 1 ||
                droppedNonMonotonicVideoFrameCount.isMultiple(of: 120) {
                programDASHStreamingLogger.error(
                    "Program output skipped non-monotonic shared video pts droppedNonMonotonicVideoFrameCount=\(self.droppedNonMonotonicVideoFrameCount, privacy: .public) frameID=\(frame.frameID, privacy: .public) ptsValue=\(presentationTime.value, privacy: .public) ptsTimescale=\(presentationTime.timescale, privacy: .public) lastPTSValue=\(lastVideoPresentationTime.value, privacy: .public) lastPTSTimescale=\(lastVideoPresentationTime.timescale, privacy: .public)"
                )
            }
            return
        }
        lastVideoPresentationTime = presentationTime
        audioRenderer.noteVideoPresentationTime(presentationTime)
        writer.append(
            pixelBuffer: frame.pixelBuffer,
            presentationTime: presentationTime
        )
    }
}
