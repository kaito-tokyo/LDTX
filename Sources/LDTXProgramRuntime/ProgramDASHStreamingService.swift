// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXCapture
import LDTXDash
import LDTXMP4
import LDTXProgram
import LDTXSupport
import OSLog

private let programDASHStreamingLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "ProgramDASHStreamingSession"
)

@MainActor
public final class ProgramDASHStreamingSession {
    private struct AudioTrackPlan {
        var key: String
        var trackID: String
        var deviceID: String
    }

    private let activeProgramRuntime: ActiveProgramRuntime
    private var renderTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var frameStreamID: UUID?
    private var segmentContinuation: AsyncStream<SegmentedMP4Segment>.Continuation?
    private var writer: SegmentedMP4Writer?
    private var recordingPackage: HLSByteRangeRecordingPackage?
    private var recordingSplitState: RecordingSplitState?
    private var audioRenderer: ProgramAudioMonitor?
    private var audioCaptureServices: [CameraCaptureService] = []
    private var audioSideRecordersByTrackID: [String: AudioSideStreamRecorder] = [:]
    private var activeEventHandler: (@MainActor (String) -> Void)?
    private var activeFailureHandler: (@MainActor (Error) -> Void)?
    private var continuityState: DASHStreamContinuityState?
    private var pendingRecordingSplit = false

    public init(activeProgramRuntime: ActiveProgramRuntime) {
        self.activeProgramRuntime = activeProgramRuntime
    }

    public var isRunning: Bool {
        renderTask != nil || uploadTask != nil
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
        failureHandler: @escaping @MainActor (Error) -> Void
    ) async throws {
        stop()
        if let shutdownTask {
            await shutdownTask.value
            self.shutdownTask = nil
        }

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

        let (segments, continuation) = AsyncStream<SegmentedMP4Segment>.makeStream()
        segmentContinuation = continuation
        let writer = try SegmentedMP4Writer(configuration: writerConfiguration) { segment in
            continuation.yield(segment)
        }
        self.writer = writer
        self.audioRenderer = audioRenderer
        audioRenderer.attach(writer: writer)
        audioRenderer.updateGains(audioChannels: snapshot.audioChannels, arguments: programArguments)
        programDASHStreamingLogger.notice(
            "Starting output session: videoPTSSource=\(snapshot.programVideoPTSInputKey ?? "host-clock", privacy: .public), audioDriver=\(snapshot.programAudioDriverKey ?? "first-received-channel", privacy: .public), audioTiming=received-frames, audioChannelCount=\(snapshot.audioChannels.count, privacy: .public)"
        )

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
            await startAudioSideStreams(
                plans: audioTrackPlans,
                excludingTrackIDs: [],
                package: package,
                segmentDurationSeconds: writerConfiguration.segmentDurationSeconds,
                eventHandler: eventHandler
            )
            eventHandler("Recording package started: \(package.directory.path)")
        } else {
            recordingSplitState = nil
        }

        uploadTask = Task { [weak self] in
            do {
                for await segment in segments {
                    self?.noteMainSegment(segment)
                    if let mainTrack = await MainActor.run(body: { self?.recordingPackage?.mainTrack }) {
                        do {
                            try await mainTrack.write(segment)
                        } catch {
                            let nsError = error as NSError
                            programDASHStreamingLogger.error("Recording package main track write failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)")
                            await MainActor.run {
                                failureHandler(error)
                                self?.stop()
                            }
                            return
                        }
                    }
                    if let pipeline {
                        let event = try await pipeline.upload(segment)
                        await MainActor.run {
                            eventHandler(Self.eventDescription(event))
                        }
                    }
                    if case .media = segment.kind {
                        try await self?.performPendingRecordingSplitIfNeeded()
                    }
                }
            } catch {
                let nsError = error as NSError
                programDASHStreamingLogger.error("Output upload task failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)")
                await MainActor.run {
                    failureHandler(error)
                    self?.stop()
                }
            }
        }

        activeProgramRuntime.beginOutput(snapshot: snapshot)
        let (frameStreamID, frames) = activeProgramRuntime.frameStream()
        self.frameStreamID = frameStreamID
        renderTask = Task { [weak self] in
            defer {
                self?.activeProgramRuntime.removeFrameStream(id: frameStreamID)
            }

            var lastVideoPresentationTime: CMTime?
            var droppedNonMonotonicVideoFrameCount = 0
            var droppedMissingVideoPTSFrameCount = 0
            for await frame in frames {
                guard !Task.isCancelled else { break }
                let presentationTime: CMTime
                if let framePresentationTime = frame.presentationTime {
                    presentationTime = framePresentationTime
                } else {
                    droppedMissingVideoPTSFrameCount += 1
                    if droppedMissingVideoPTSFrameCount == 1 ||
                        droppedMissingVideoPTSFrameCount.isMultiple(of: 120) {
                        programDASHStreamingLogger.error(
                            "Program output skipped frame without shared video pts droppedMissingVideoPTSFrameCount=\(droppedMissingVideoPTSFrameCount, privacy: .public) frameID=\(frame.frameID, privacy: .public) videoPTSSource=\(snapshot.programVideoPTSInputKey ?? "nil", privacy: .public)"
                        )
                    }
                    continue
                }
                if let lastVideoPresentationTime,
                   CMTimeCompare(presentationTime, lastVideoPresentationTime) <= 0 {
                    droppedNonMonotonicVideoFrameCount += 1
                    if droppedNonMonotonicVideoFrameCount == 1 ||
                        droppedNonMonotonicVideoFrameCount.isMultiple(of: 120) {
                        programDASHStreamingLogger.error(
                            "Program output skipped non-monotonic shared video pts droppedNonMonotonicVideoFrameCount=\(droppedNonMonotonicVideoFrameCount, privacy: .public) frameID=\(frame.frameID, privacy: .public) ptsValue=\(presentationTime.value, privacy: .public) ptsTimescale=\(presentationTime.timescale, privacy: .public) lastPTSValue=\(lastVideoPresentationTime.value, privacy: .public) lastPTSTimescale=\(lastVideoPresentationTime.timescale, privacy: .public)"
                        )
                    }
                    continue
                }
                lastVideoPresentationTime = presentationTime
                audioRenderer.noteVideoPresentationTime(presentationTime)
                writer.append(
                    pixelBuffer: frame.pixelBuffer,
                    presentationTime: presentationTime
                )
            }
        }
    }

    public func stop() {
        guard shutdownTask == nil else {
            return
        }
        guard renderTask != nil ||
            uploadTask != nil ||
            writer != nil ||
            recordingPackage != nil ||
            segmentContinuation != nil ||
            !audioSideRecordersByTrackID.isEmpty ||
            !audioCaptureServices.isEmpty ||
            frameStreamID != nil ||
            audioRenderer != nil ||
            activeEventHandler != nil ||
            activeFailureHandler != nil ||
            pendingRecordingSplit ||
            recordingSplitState != nil else {
            return
        }

        renderTask?.cancel()
        renderTask = nil
        if let frameStreamID {
            activeProgramRuntime.removeFrameStream(id: frameStreamID)
            self.frameStreamID = nil
        }
        activeProgramRuntime.endOutput()

        let segmentContinuation = segmentContinuation
        self.segmentContinuation = nil
        let uploadTask = uploadTask
        self.uploadTask = nil
        let writer = writer
        self.writer = nil
        audioRenderer?.detachWriter()
        audioRenderer = nil
        let audioCaptureServices = audioCaptureServices
        self.audioCaptureServices = []
        let audioSideRecordersByTrackID = audioSideRecordersByTrackID
        self.audioSideRecordersByTrackID = [:]
        let recordingPackage = recordingPackage
        self.recordingPackage = nil
        let failureHandler = activeFailureHandler
        activeFailureHandler = nil
        activeEventHandler = nil
        pendingRecordingSplit = false
        recordingSplitState = nil

        let shutdownTask = Task {
            for service in audioCaptureServices {
                await service.stop()
            }
            for recorder in audioSideRecordersByTrackID.values {
                await recorder.finish()
            }
            do {
                try await writer?.finish()
            } catch {
                let nsError = error as NSError
                programDASHStreamingLogger.error("Segmented MP4 writer finish failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)")
                await MainActor.run {
                    failureHandler?(error)
                }
            }
            segmentContinuation?.finish()
            await uploadTask?.value
            await recordingPackage?.finish()
        }
        self.shutdownTask = shutdownTask
    }

    private func noteMainSegment(_ segment: SegmentedMP4Segment) {
        continuityState?.noteMainSegment(segment)
    }

    private func performPendingRecordingSplitIfNeeded() async throws {
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
            try await nextPackage.mainTrack.write(
                SegmentedMP4Segment(kind: .initialization, data: latestInitSegment)
            )
        }
        for (trackID, recorder) in audioSideRecordersByTrackID {
            guard let trackRecorder = nextPackage.audioTracks[trackID] else {
                continue
            }
            try await recorder.rotate(to: trackRecorder)
        }
        Task {
            await currentPackage.finish()
        }
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
        excludingTrackIDs: Set<String>,
        package: HLSByteRangeRecordingPackage,
        segmentDurationSeconds: Int,
        eventHandler: @escaping @MainActor (String) -> Void
    ) async {
        for plan in plans {
            guard !excludingTrackIDs.contains(plan.trackID) else {
                continue
            }
            guard let trackRecorder = package.audioTracks[plan.trackID] else {
                continue
            }
            let captureService = CameraCaptureService()
            do {
                let sideRecorder = try AudioSideStreamRecorder(
                    trackRecorder: trackRecorder,
                    segmentDurationSeconds: segmentDurationSeconds,
                    onInitializationSegment: { [weak self] data in
                        Task { [weak self] in
                            await MainActor.run {
                                self?.continuityState?.latestAudioInitSegments[plan.trackID] = data
                            }
                        }
                    }
                )
                try await captureService.startAudioCapture(audioDeviceID: plan.deviceID) { sampleBuffer, kind in
                    guard kind == .audio else { return }
                    sideRecorder.append(sampleBuffer)
                }
                audioCaptureServices.append(captureService)
                audioSideRecordersByTrackID[plan.trackID] = sideRecorder
            } catch {
                let nsError = error as NSError
                programDASHStreamingLogger.error("Audio side stream failed key=\(plan.key, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)")
                eventHandler("Audio side stream failed: \(plan.key): \(error.localizedDescription)")
            }
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
