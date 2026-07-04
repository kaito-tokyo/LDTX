// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXCapture
import LDTXDash
import LDTXMedia
import LDTXProgram
import LDTXSupport
import OSLog

private let programDASHStreamingLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "ProgramDASHStreamingSession"
)

@MainActor
final class ProgramDASHStreamingSession {
    private struct AudioTrackPlan {
        var key: String
        var trackID: String
        var deviceID: String
    }

    private let renderWorker: ProgramPreviewRenderWorker
    private var renderTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var segmentContinuation: AsyncStream<SegmentedMP4Segment>.Continuation?
    private var writer: SegmentedMP4Writer?
    private var recordingPackage: HLSByteRangeRecordingPackage?
    private var audioRenderer: ProgramAudioMonitor?
    private var audioCaptureServices: [CameraCaptureService] = []
    private var audioSideRecorders: [AudioSideStreamRecorder] = []
    private var activeFailureHandler: (@MainActor (Error) -> Void)?
    private var sessionID = 0

    init(cameraInputSource: ProgramCameraInputSource) {
        renderWorker = ProgramPreviewRenderWorker(cameraInputSource: cameraInputSource)
    }

    var isRunning: Bool {
        renderTask != nil || uploadTask != nil
    }

    func start(
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

        let frameRate = max(snapshot.frameRate, 1)
        let audioTrackPlans = audioTrackPlans(from: audioDeviceIDsByInputKey)
        let writerConfiguration = SegmentedMP4WriterConfiguration(
            width: snapshot.outputWidth,
            height: snapshot.outputHeight,
            frameRate: frameRate,
            videoBitRate: videoBitRate(width: snapshot.outputWidth, height: snapshot.outputHeight, frameRate: frameRate)
        )
        let (segments, continuation) = AsyncStream<SegmentedMP4Segment>.makeStream()
        segmentContinuation = continuation
        let writer = try SegmentedMP4Writer(configuration: writerConfiguration) { segment in
            continuation.yield(segment)
        }
        self.writer = writer
        self.audioRenderer = audioRenderer
        audioRenderer.attach(writer: writer)
        audioRenderer.updateGains(composite: snapshot.composite, arguments: programArguments)
        programDASHStreamingLogger.notice(
            "Starting output session: videoPTSSource=\(snapshot.programVideoPTSInputKey ?? "host-clock", privacy: .public), audioDriver=\(snapshot.programAudioDriverKey ?? "first-received-channel", privacy: .public), audioTiming=received-frames, audioChannelCount=\(snapshot.composite.audioChannels.count, privacy: .public)"
        )
        let pipeline: DASHLiveUploadPipeline? = if let endpoint {
            DASHLiveUploadPipeline(
                endpoint: endpoint,
                manifestConfiguration: DASHManifestConfiguration(
                    availabilityStartTime: Date(),
                    timescale: writerConfiguration.timescale,
                    segmentDurationSeconds: writerConfiguration.segmentDurationSeconds,
                    startNumber: writerConfiguration.startNumber,
                    mediaTemplate: endpoint.mpdReference(for: "media$Number%09d$.mp4"),
                    initialization: .embedded(data: Data()),
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
            let recordingDirectory = recordingBaseDirectory
                .appendingPathComponent(recordID, isDirectory: true)
                .appendingPathExtension("ldtxrecord")
            let mainStreamURL = recordingDirectory.appendingPathComponent("main-stream.mp4", isDirectory: false)
            let mainPlaylistURL = recordingDirectory.appendingPathComponent("main-stream.m3u8", isDirectory: false)
            let sideRecordingTracks = audioTrackPlans.enumerated().map { index, plan in
                let fileNameStem = index == 0 ? "side-track" : "side-track-\(index + 1)"
                return HLSByteRangeRecordingAudioTrack(
                    id: plan.trackID,
                    displayName: plan.key,
                    fileNameStem: fileNameStem
                )
            }
            let package = try HLSByteRangeRecordingPackage(
                configuration: HLSByteRangeRecordingPackageConfiguration(
                    directory: recordingDirectory,
                    recordID: recordID,
                    targetDurationSeconds: writerConfiguration.segmentDurationSeconds,
                    videoCodecs: "avc1.64002a",
                    audioCodecs: "mp4a.40.2",
                    bandwidth: writerConfiguration.videoBitRate + writerConfiguration.audioBitRate,
                    includesMainAudioTrack: true,
                    audioTracks: sideRecordingTracks
                )
            )
            programDASHStreamingLogger.notice(
                "Recording package paths: directory=\(recordingDirectory.path, privacy: .public), mainStream=\(mainStreamURL.path, privacy: .public), mainPlaylist=\(mainPlaylistURL.path, privacy: .public), audioTrackCount=\(sideRecordingTracks.count, privacy: .public)"
            )
            for track in sideRecordingTracks {
                let mediaURL = recordingDirectory.appendingPathComponent("\(track.fileNameStem).mp4", isDirectory: false)
                let playlistURL = recordingDirectory.appendingPathComponent("\(track.fileNameStem).m3u8", isDirectory: false)
                programDASHStreamingLogger.notice(
                    "Recording side track path: id=\(track.id, privacy: .public), displayName=\(track.displayName, privacy: .public), media=\(mediaURL.path, privacy: .public), playlist=\(playlistURL.path, privacy: .public)"
                )
            }
            recordingPackage = package
            await startAudioSideStreams(
                plans: audioTrackPlans,
                excludingTrackIDs: [],
                package: package,
                segmentDurationSeconds: writerConfiguration.segmentDurationSeconds,
                eventHandler: eventHandler
            )
            eventHandler("Recording package started: \(recordingDirectory.path)")
        }
        activeFailureHandler = failureHandler
        uploadTask = Task { [weak self] in
            do {
                for await segment in segments {
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

        sessionID += 1
        let sessionID = sessionID
        let renderWorker = renderWorker
        renderTask = Task { [weak self] in
            await renderWorker.beginSession(sessionID)
            defer {
                Task {
                    await renderWorker.endSession(sessionID)
                }
            }

            let frameClock = ProgramOutputFrameClock(frameRate: frameRate)
            var lastVideoPresentationTime: CMTime?
            var droppedNonMonotonicVideoFrameCount = 0
            var droppedMissingVideoPTSFrameCount = 0
            for await _ in frameClock.ticks {
                guard !Task.isCancelled else { break }
                var frameSnapshot = snapshot
                frameSnapshot.timeSeconds = Float(ProcessInfo.processInfo.systemUptime)
                do {
                    let frame = try await renderWorker.render(
                        snapshot: frameSnapshot,
                        sessionID: sessionID
                    )
                    let presentationTime: CMTime
                    if let framePresentationTime = frame.presentationTime {
                        presentationTime = framePresentationTime
                    } else if snapshot.programVideoPTSInputKey == nil {
                        presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
                    } else {
                        droppedMissingVideoPTSFrameCount += 1
                        if droppedMissingVideoPTSFrameCount == 1 ||
                            droppedMissingVideoPTSFrameCount.isMultiple(of: 120) {
                            programDASHStreamingLogger.error(
                                "Program output skipped frame without selected video pts droppedMissingVideoPTSFrameCount=\(droppedMissingVideoPTSFrameCount, privacy: .public) videoPTSSource=\(snapshot.programVideoPTSInputKey ?? "nil", privacy: .public)"
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
                                "Program output skipped non-monotonic video pts droppedNonMonotonicVideoFrameCount=\(droppedNonMonotonicVideoFrameCount, privacy: .public) ptsValue=\(presentationTime.value, privacy: .public) ptsTimescale=\(presentationTime.timescale, privacy: .public) lastPTSValue=\(lastVideoPresentationTime.value, privacy: .public) lastPTSTimescale=\(lastVideoPresentationTime.timescale, privacy: .public)"
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
                } catch {
                    let nsError = error as NSError
                    programDASHStreamingLogger.error("Program render failed during output errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)")
                    await MainActor.run {
                        failureHandler(error)
                        self?.stop()
                    }
                    return
                }
            }
        }
    }

    func stop() {
        renderTask?.cancel()
        renderTask = nil
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
        let audioSideRecorders = audioSideRecorders
        self.audioSideRecorders = []
        let recordingPackage = recordingPackage
        self.recordingPackage = nil
        let failureHandler = activeFailureHandler
        activeFailureHandler = nil
        Task {
            for service in audioCaptureServices {
                await service.stop()
            }
            for recorder in audioSideRecorders {
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
                    segmentDurationSeconds: segmentDurationSeconds
                )
                try await captureService.startAudioCapture(audioDeviceID: plan.deviceID) { sampleBuffer, kind in
                    guard kind == .audio else { return }
                    sideRecorder.append(sampleBuffer)
                }
                audioCaptureServices.append(captureService)
                audioSideRecorders.append(sideRecorder)
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

private final class ProgramOutputFrameClock: @unchecked Sendable {
    let ticks: AsyncStream<Void>

    init(frameRate: Int) {
        let frameRate = max(frameRate, 1)
        let frameIntervalNanoseconds = max(1, 1_000_000_000 / frameRate)
        let queue = DispatchQueue(label: "tokyo.kaito.ldtx.ProgramOutputFrameClock")
        let timer = DispatchSource.makeTimerSource(queue: queue)

        ticks = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            timer.setEventHandler {
                continuation.yield(())
            }
            timer.schedule(
                deadline: .now(),
                repeating: .nanoseconds(frameIntervalNanoseconds),
                leeway: .milliseconds(1)
            )
            continuation.onTermination = { _ in
                timer.cancel()
            }
            timer.resume()
        }
    }
}
