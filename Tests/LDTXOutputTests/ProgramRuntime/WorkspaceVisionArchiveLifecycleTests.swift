// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import AudioToolbox
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import LDTXMP4
@testable import LDTXProgramRuntime
import LDTXProtos
import LDTXRecordBundleFormat
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceBundleFormat
import Synchronization
import Testing

extension OutputTestSuite {
  @MainActor
  @Suite struct WorkspaceVisionArchiveLifecycleIntegrationTestSuite {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func cutsReplaceOnlyRecordingAndFinalizeOldPackage(failReplacement: Bool, dualCanvas: Bool)
      async throws
    {
      let fixture = try Fixture(recordsPortrait: dualCanvas)
      defer { fixture.cleanup() }
      let landscape = ProgramOutputMediaHub()
      let portrait = ProgramOutputMediaHub()
      let streamCount = Mutex(0)
      let stream = landscape.subscribe(
        mainVideo: { _ in streamCount.withLock { $0 += 1 } },
        mainAudioMix: { _ in })
      fixture.session.prepareRecordingMedia(fixture.service) {
        if failReplacement { throw NSError(domain: "replacement-fixture", code: 17) }
        return try SessionRecordService(
          baseDirectory: fixture.root, recordID: "replacement",
          writerConfiguration: SegmentedMP4WriterConfiguration(
            width: 16, height: 16, frameRate: 30, videoBitRate: 100_000),
          audioTracks: [], recordsPortrait: dualCanvas,
          failureHandler: { Issue.record("Unexpected replacement error: \($0)") })
      }
      fixture.session.installRecordingSubscriptions(
        service: fixture.service,
        landscapeHub: landscape, portraitHub: portrait,
        recordsLandscape: true, recordsPortrait: dualCanvas)
      fixture.session.state = .recording
      if dualCanvas {
        portrait.publishMainAudioMix(try frameAudio())
        portrait.publishMainVideo(try videoSample())
      }
      landscape.publishMainAudioMix(try frameAudio())
      landscape.publishMainVideo(try videoSample())
      while !fixture.session.canCutRecording { await Task.yield() }
      var releaseOCR: CheckedContinuation<Void, Never>?
      var recognized: String?
      var variableResult: String?
      var vision = Ldtx_Workspace_V4_OcrVision()
      vision.internalID = 41
      var context = fixture.runtime.visionFeatureContext
      context.vision = { $0 == 41 ? vision : nil }
      context.frameForVision = { _ in
        .init(image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)))
      }
      context.reportResult = { _, value in recognized = value }
      context.reportVariables = { _, values in variableResult = values[.text] }
      let feature = WorkspaceV4VisionFeature(
        scheduler: WorkspaceVisionScheduler(now: { 0 }, random: { _ in 0 }, automaticTimer: false),
        recognizeText: { _, _ in
          await withCheckedContinuation { releaseOCR = $0 }
          return "in-flight cut result"
        })
      var wrapper = Ldtx_Workspace_V4_VisionWrapper()
      wrapper.ocrVision = vision
      feature.synchronize(visions: [wrapper], context: context)
      feature.runOCR(visionInternalID: 41)
      while releaseOCR == nil { await Task.yield() }
      let cut = Task { await fixture.session.cutWithResult() }
      while !fixture.session.isCutPending { await Task.yield() }
      #expect(fixture.runtime.visionArchivePackageURL == nil)
      // A second request cannot establish another replacement while the first waits.
      if case .success = await fixture.session.cutWithResult() {
        Issue.record("Repeated cut must be rejected")
      }
      for frame in 1...5 {
        if dualCanvas {
          portrait.publishMainAudioMix(try retime(frameAudio(), frame: Int64(frame)))
          portrait.publishMainVideo(try retime(videoSample(), frame: Int64(frame)))
        }
        landscape.publishMainAudioMix(try retime(frameAudio(), frame: Int64(frame)))
        landscape.publishMainVideo(try retime(videoSample(), frame: Int64(frame)))
        await Task.yield()
      }
      let result = await cut.value
      if failReplacement {
        if case .failure(let error) = result {
          #expect(error.code == 17)
        } else {
          Issue.record("Replacement preparation should fail")
        }
        #expect(!fixture.isFinalized)
        #expect(fixture.runtime.visionArchivePackageURL == fixture.package)
      } else {
        try result.get()
        #expect(fixture.isFinalized)
        #expect(
          fixture.runtime.visionArchivePackageURL?.lastPathComponent == "replacement.ldtxrecord")
      }
      #expect(fixture.session.state == .recording)
      releaseOCR?.resume()
      while !feature.canRunOCR(visionInternalID: 41) { await Task.yield() }
      #expect(recognized == "in-flight cut result")
      #expect(variableResult == "in-flight cut result")
      await feature.stop()
      landscape.publishMainAudioMix(try retime(frameAudio(), frame: 6))
      landscape.publishMainVideo(try retime(videoSample(), frame: 6))
      if dualCanvas {
        portrait.publishMainAudioMix(try retime(frameAudio(), frame: 6))
        portrait.publishMainVideo(try retime(videoSample(), frame: 6))
      }
      try (await fixture.session.stopWithResult()).get()
      _ = await landscape.unsubscribeAndDrain(stream)
      #expect(streamCount.withLock { $0 } == 7)
      #expect(fixture.isFinalized)
      #expect(fixture.hasArchives == failReplacement)
      if !failReplacement {
        #expect(
          !FileManager.default.fileExists(
            atPath: fixture.root
              .appendingPathComponent("replacement.ldtxrecord/Visions").path))
      }
      let packages =
        failReplacement
        ? [fixture.package]
        : [fixture.package, fixture.root.appendingPathComponent("replacement.ldtxrecord")]
      for package in packages {
        let landscapeTiming = try await mediaTiming(
          package.appendingPathComponent("landscape.fragmented.mp4"))
        #expect(CMTimeCompare(landscapeTiming.start, .zero) == 0)
        // AAC padding can differ from the video endpoint by one packet.
        #expect(
          abs(CMTimeSubtract(landscapeTiming.videoDuration, landscapeTiming.audioDuration).seconds)
            <= 1024.0 / 48000 + 0.001)
        if dualCanvas {
          let portraitTiming = try await mediaTiming(
            package.appendingPathComponent("portrait.fragmented.mp4"))
          #expect(CMTimeCompare(landscapeTiming.start, portraitTiming.start) == 0)
          #expect(CMTimeCompare(landscapeTiming.videoDuration, portraitTiming.videoDuration) == 0)
          #expect(CMTimeCompare(landscapeTiming.audioDuration, portraitTiming.audioDuration) == 0)
        }
      }
    }

    @Test(.timeLimit(.minutes(1)), arguments: Finish.allCases)
    func stopRollsBackWaitingCutAndDrainsIt(finishing: Finish) async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let hub = ProgramOutputMediaHub()
      fixture.session.prepareRecordingMedia(fixture.service) {
        Issue.record("Stop must not prepare a replacement")
        return fixture.service
      }
      fixture.session.installRecordingSubscriptions(
        service: fixture.service,
        landscapeHub: hub, portraitHub: ProgramOutputMediaHub(),
        recordsLandscape: true, recordsPortrait: false)
      fixture.session.state = .recording
      hub.publishMainAudioMix(try audioSample())
      hub.publishMainVideo(try videoSample())
      while !fixture.session.canCutRecording { await Task.yield() }
      let cut = Task { await fixture.session.cutWithResult() }
      while !fixture.session.isCutPending { await Task.yield() }
      try
        (await
        (finishing == .stop
        ? fixture.session.stopWithResult()
        : fixture.session.pauseWithResult())).get()
      try (await cut.value).get()
      if finishing == .pauseThenStop { try (await fixture.session.stopWithResult()).get() }
      #expect(fixture.session.state == (finishing == .pause ? .paused : .idle))
      #expect(fixture.isFinalized)
    }

    @Test(.timeLimit(.minutes(1)))
    func cutTimeoutReleasesCrossCanvasBarrierAndLeavesRecordingActive() async throws {
      let fixture = try Fixture(recordsPortrait: true, cutBoundaryTimeout: .milliseconds(50))
      defer { fixture.cleanup() }
      let landscape = ProgramOutputMediaHub()
      let portrait = ProgramOutputMediaHub()
      fixture.session.prepareRecordingMedia(fixture.service) {
        Issue.record("A blocked boundary must not prepare a replacement")
        return fixture.service
      }
      let subscriptions = fixture.session.installRecordingSubscriptions(
        service: fixture.service,
        landscapeHub: landscape, portraitHub: portrait, recordsLandscape: true,
        recordsPortrait: true)
      fixture.session.state = .recording
      for hub in [landscape, portrait] {
        hub.publishMainAudioMix(try frameAudio())
        hub.publishMainVideo(try videoSample())
      }
      while !fixture.session.canCutRecording { await Task.yield() }
      let release = DispatchSemaphore(value: 0)
      defer { release.signal() }
      try #require(portrait.enqueueControl(subscriptions[1]) { release.wait() })
      if case .success = await fixture.session.cutWithResult() {
        Issue.record("A blocked cross-canvas boundary must time out")
      }
      // This control is behind Landscape's barrier. It can only complete when
      // timeout has released that barrier, even while Portrait is still blocked.
      await withCheckedContinuation { continuation in
        let accepted = landscape.enqueueControl(subscriptions[0]) { continuation.resume() }
        if !accepted { continuation.resume() }
      }
      #expect(fixture.session.state == .recording)
      #expect(fixture.session.canCutRecording)
      release.signal()
      try (await fixture.session.stopWithResult()).get()
      #expect(fixture.isFinalized)
    }

    @Test(.timeLimit(.minutes(1)))
    func queuedOldPackageFailureDoesNotStopReplacement() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      try fixture.service.acceptFirstVideo(videoSample())
      fixture.service.appendMainAudioMix(try audioSample())
      fixture.session.state = .recording
      let replacement = try SessionRecordService(
        baseDirectory: fixture.root, recordID: "new-owner",
        writerConfiguration: SegmentedMP4WriterConfiguration(
          width: 16, height: 16, frameRate: 30, videoBitRate: 100_000),
        audioTracks: [], failureHandler: { Issue.record("Unexpected replacement fault: \($0)") })
      try replacement.start()
      try replacement.acceptFirstVideo(videoSample())
      replacement.appendMainAudioMix(try audioSample())
      // Queue an old-owner callback, then commit the replacement before the
      // callback's MainActor task runs. It must revalidate ownership at execution.
      fixture.session.recordingServiceDidFail(
        NSError(domain: "old-owner", code: 23),
        packageURL: fixture.package)
      fixture.session.adoptStartedRecordingService(replacement)
      fixture.session.recordingServiceDidFail(
        NSError(domain: "cancelled-replacement", code: 24),
        packageURL: fixture.root.appendingPathComponent("cancelled.ldtxrecord"))
      await Task.yield()
      #expect(fixture.session.state == .recording)
      #expect(fixture.session.outputFailures.primary == nil)
      _ = await withCheckedContinuation { continuation in
        fixture.service.finishAfterCut { continuation.resume(returning: $0) }
      }
      try (await fixture.session.stopWithResult()).get()
      #expect(fixture.isFinalized)
      #expect(
        FileManager.default.fileExists(
          atPath: replacement.packageDirectory
            .appendingPathComponent(RecordingPackage.finalizedMarkerFileName).path))
    }

    private func mediaTiming(_ url: URL) async throws -> (
      start: CMTime, videoDuration: CMTime, audioDuration: CMTime
    ) {
      let asset = AVURLAsset(url: url)
      let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
      let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
      let videoRange = try await video.load(.timeRange)
      let audioRange = try await audio.load(.timeRange)
      for track in [video, audio] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var last: CMTime?
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
          // Readers may emit empty control buffers, or group multiple media
          // samples. Inspect each media sample's timing rather than the wrapper.
          for index in 0..<CMSampleBufferGetNumSamples(sample) {
            var timing = CMSampleTimingInfo()
            try #require(
              CMSampleBufferGetSampleTimingInfo(
                sample, at: index,
                timingInfoOut: &timing) == noErr)
            let pts = timing.presentationTimeStamp
            #expect(pts.isNumeric)
            if let last { #expect(CMTimeCompare(pts, last) > 0) }
            last = pts
            count += 1
          }
        }
        #expect(count > 0)
        #expect(reader.status == .completed)
      }
      return (videoRange.start, videoRange.duration, audioRange.duration)
    }

    private func frameAudio() throws -> CMSampleBuffer {
      try audioSample(frameCount: 1600)
    }

    private func retime(_ sample: CMSampleBuffer, frame: Int64, timescale: Int32 = 30) throws
      -> CMSampleBuffer
    {
      var timing = CMSampleTimingInfo()
      #expect(CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr)
      timing.presentationTimeStamp = CMTime(value: frame, timescale: timescale)
      timing.decodeTimeStamp = .invalid
      var copy: CMSampleBuffer?
      #expect(
        CMSampleBufferCreateCopyWithNewTiming(
          allocator: kCFAllocatorDefault,
          sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
          sampleBufferOut: &copy) == noErr)
      return try #require(copy)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func dualBoundaryRoutesMixedAndLateInputAudioByPTS(failCommit: Bool) async throws {
      let core = WorkspaceRecordMediaCore()
      let previous = BoundaryRecorder()
      let replacement = BoundaryRecorder()
      replacement.failFirstVideo = failCommit
      var boundary: UUID?
      core.setCallbacks(
        commitRequest: { boundary = $0 }, eventHandler: { _ in },
        failureHandler: { Issue.record("Unexpected delivery error: \($0)") },
        cutStateChanged: { _ in })
      core.install(previous)
      let operationID = UUID()
      core.enqueueMainAudio(try audioSample())
      core.enqueuePortraitAudio(try audioSample())
      await core.waitForPendingOperations()
      // A callback acquired before commit can arrive late and belongs to the old
      // package only when its PTS precedes the committed recording boundary.
      let oldCallback = try #require(core.beginInputAudioCallback())
      let newCallback = try #require(core.beginInputAudioCallback())
      let crossingCallback = try #require(core.beginInputAudioCallback())
      core.enqueueCutRequest(for: previous)
      core.enqueueMainAudio(try retime(audioSample(), frame: 2, timescale: 10))
      core.enqueuePortraitAudio(try retime(audioSample(), frame: 2, timescale: 10))
      core.enqueueMainAudio(try retime(audioSample(), frame: 5, timescale: 20))
      core.enqueuePortraitAudio(try retime(audioSample(), frame: 5, timescale: 20))
      core.enqueueVideo(
        try retime(videoSample(), frame: 3, timescale: 10), operationID: operationID)
      core.enqueuePortraitVideo(
        try retime(videoSample(), frame: 3, timescale: 10), operationID: operationID)
      while boundary == nil { await Task.yield() }
      let result = await withCheckedContinuation { continuation in
        core.enqueueCommit(
          boundaryID: boundary!, operationID: operationID,
          replacement: replacement
        ) { continuation.resume(returning: $0) }
      }
      if failCommit {
        if case .success = result { Issue.record("Commit should fail") }
      } else {
        #expect(try result.get() != nil)
      }
      core.enqueueInputAudio(
        try retime(audioSample(), frame: 2, timescale: 10), trackID: "input",
        callback: oldCallback)
      core.enqueueInputAudio(
        try retime(audioSample(), frame: 4, timescale: 10), trackID: "input",
        callback: newCallback)
      core.enqueueInputAudio(
        try retime(audioSample(), frame: 5, timescale: 20),
        trackID: "input", callback: crossingCallback)
      core.enqueueMainAudio(try retime(audioSample(), frame: 4, timescale: 10))
      core.enqueuePortraitAudio(try retime(audioSample(), frame: 4, timescale: 10))
      await core.waitForPendingOperations()
      let old = previous.events.withLock { $0 }
      let new = replacement.events.withLock { $0 }
      #expect(old.contains("input:2"))
      #expect(old.contains("landscapeAudio:2"))
      #expect(old.contains("portraitAudio:2"))
      if failCommit {
        #expect(old.contains("input:4"))
        #expect(old.contains("landscapeVideo:3"))
        #expect(old.contains("portraitVideo:3"))
      } else {
        #expect(!old.contains("input:4"))
        #expect(new.contains("input:4"))
        #expect(new.contains("landscapeVideo:3"))
        #expect(new.contains("portraitVideo:3"))
        #expect(new.contains("landscapeAudio:4"))
        #expect(new.contains("portraitAudio:4"))
        for kind in ["input", "landscapeAudio", "portraitAudio"] {
          #expect(old.contains("\(kind)Count:2400"))
          #expect(new.contains("\(kind)Count:2400"))
        }
      }
      _ = await core.closeAndDrain()
    }

    private final class BoundaryRecorder: SessionRecordServicing, @unchecked Sendable {
      let packageDirectory = URL(fileURLWithPath: "/tmp/boundary-fixture.ldtxrecord")
      let hasAcceptedFirstVideo = true
      let recordsLandscapeOutput = true
      let recordsPortraitOutput = true
      var failFirstVideo = false
      let events = Mutex<[String]>([])
      func add(_ kind: String, _ sample: CMSampleBuffer) {
        let frame = CMTimeConvertScale(
          sample.presentationTimeStamp, timescale: 10,
          method: .default
        ).value
        events.withLock {
          $0.append("\(kind):\(frame)")
          $0.append("\(kind)Count:\(CMSampleBufferGetNumSamples(sample))")
        }
      }
      @MainActor func start() throws {}
      func acceptFirstVideo(
        _ sample: CMSampleBuffer,
        mainAudioFormatDescription: CMAudioFormatDescription?
      ) throws {
        if failFirstVideo { throw NSError(domain: "first-video-fixture", code: 19) }
        appendMainVideo(sample)
      }
      func acceptFirstPortraitVideo(
        _ sample: CMSampleBuffer,
        mainAudioFormatDescription: CMAudioFormatDescription?
      ) throws { appendPortraitVideo(sample) }
      func appendMainVideo(_ sample: CMSampleBuffer) { add("landscapeVideo", sample) }
      func appendPortraitVideo(_ sample: CMSampleBuffer) { add("portraitVideo", sample) }
      func appendMainAudioMix(_ sample: CMSampleBuffer) { add("landscapeAudio", sample) }
      func appendPortraitAudioMix(_ sample: CMSampleBuffer) { add("portraitAudio", sample) }
      func appendInputAudio(_ sample: CMSampleBuffer, trackID: String) { add("input", sample) }
      func sealInputAudio() {}
      @MainActor func stop(
        completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void
      ) { completionHandler(.finalized) }
      @MainActor func finishAfterCut(
        completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void
      ) { completionHandler(.finalized) }
      @MainActor func stopPreservingIncompletePackage(
        completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void
      ) { completionHandler(.preservedIncomplete) }
      @MainActor func abandonAfterMediaDrainTimeout() {}
      @MainActor func cancelBeforeFirstVideo(
        completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void
      ) { completionHandler(.finalized) }
      func recordingTimelineMilliseconds() -> UInt64? { 0 }
    }

    enum Finish: CaseIterable { case stop, pause, pauseThenStop }
    enum InactiveScreenshotState: CaseIterable {
      case idle, starting, pausing, paused, stopping, failed
      var state: WorkspaceV4RecordingSession.State {
        switch self {
        case .idle: .idle
        case .starting: .starting
        case .pausing: .pausing
        case .paused: .paused
        case .stopping: .stopping
        case .failed: .failed("test")
        }
      }
    }

    @Test(.timeLimit(.minutes(1)), arguments: Finish.allCases)
    func manualOCRUsesRecordingArchive(finishing: Finish) async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      try fixture.service.acceptFirstVideo(videoSample())
      fixture.service.appendMainAudioMix(try audioSample())
      fixture.session.state = .recording
      var vision = Ldtx_Workspace_V4_OcrVision()
      vision.internalID = 41
      var displayed: String?
      var context = fixture.runtime.visionFeatureContext
      context.vision = { $0 == 41 ? vision : nil }
      context.frameForVision = { _ in
        .init(image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)))
      }
      context.reportResult = { _, text in displayed = text }
      context.reportVariables = { _, _ in }
      context.reportFailure = { _, error in Issue.record("Unexpected OCR failure: \(error)") }
      let feature = WorkspaceV4VisionFeature(
        scheduler: WorkspaceVisionScheduler(now: { 0 }, random: { _ in 0 }, automaticTimer: false),
        recognizeText: { _, _ in "manual recording result" })
      var wrapper = Ldtx_Workspace_V4_VisionWrapper()
      wrapper.ocrVision = vision
      feature.synchronize(visions: [wrapper], context: context)
      feature.runOCR(visionInternalID: 41)
      while !feature.canRunOCR(visionInternalID: 41) { await Task.yield() }
      #expect(displayed == "manual recording result")
      let result =
        finishing == .stop
        ? await fixture.session.stopWithResult() : await fixture.session.pauseWithResult()
      try result.get()
      if finishing == .pauseThenStop { try (await fixture.session.stopWithResult()).get() }
      let metadata = try fixture.archiveMetadata()
      #expect(metadata["visionID"] == "41")
      #expect(metadata["output"] == "manual recording result")
      #expect(metadata["recordingTimelineMilliseconds"] != nil)
      await feature.stop()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], Finish.allCases)
    func stopDoesNotWaitForOtherWorkspaceScreenshot(ownCaptureFinished: Bool, finishing: Finish)
      async throws
    {
      let fixture = try Fixture(screenCaptureService: ScreenCaptureService())
      defer { fixture.cleanup() }
      try fixture.service.acceptFirstVideo(videoSample())
      fixture.service.appendMainAudioMix(try audioSample())
      fixture.session.state = .recording
      if ownCaptureFinished { try await fixture.screenshot() }
      let manager = OtherWorkspaceBlockingFileManager()
      defer { manager.release.signal() }
      let other = ScreenCaptureService(fileManager: manager)
      var buffer: CVPixelBuffer?
      #expect(
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer)
          == kCVReturnSuccess)
      let source = try other.snapshot(pixelBuffer: #require(buffer), name: "OtherWorkspace")
      let otherCapture = Task {
        try await other.enqueueCapture(
          sources: [source], capturedAt: Date(),
          outputDirectories: [fixture.root.appendingPathComponent("other-global")])
      }
      while !manager.started.withLock({ $0 }) { await Task.yield() }
      var stopped = false
      let stop = Task {
        let result =
          finishing == .stop
          ? await fixture.session.stopWithResult() : await fixture.session.pauseWithResult()
        try result.get()
        if finishing == .pauseThenStop { try (await fixture.session.stopWithResult()).get() }
        stopped = true
      }
      try await fixture.waitForAdmissionToClose()
      try await stop.value
      #expect(stopped)
      #expect(fixture.isFinalized)
      #expect(!manager.unblocked.withLock { $0 })
      manager.release.signal()
      _ = try await otherCapture.value
      try await stop.value
      #expect(fixture.isFinalized)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], Finish.allCases)
    func queuedScreenshotsDrainBeforeStopAndCancellation(firstVideo: Bool, finishing: Finish)
      async throws
    {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      if firstVideo {
        try fixture.service.acceptFirstVideo(videoSample())
        fixture.service.appendMainAudioMix(try audioSample())
      }
      fixture.session.state = .recording
      let release = DispatchSemaphore(value: 0)
      fixture.screenshotQueue.async { _ = release.wait(timeout: .now() + 15) }
      defer { release.signal() }
      var started = false
      var saved = false
      let capture = Task {
        started = true
        try await fixture.screenshot()
        saved = true
      }
      while !started { await Task.yield() }
      // Reaching here while the background queue is blocked proves MainActor responds.
      #expect(!saved)
      var secondStarted = false
      let second = Task {
        secondStarted = true
        try await fixture.screenshot()
      }
      while !secondStarted { await Task.yield() }
      do {
        try await fixture.screenshot()
        Issue.record("A third capture must not retain another frame set")
      } catch ScreenCaptureError.captureBusy {} catch { Issue.record(error) }
      var stopped = false
      let stop = Task {
        let result =
          finishing == .stop
          ? await fixture.session.stopWithResult() : await fixture.session.pauseWithResult()
        try result.get()
        if finishing == .pauseThenStop { try (await fixture.session.stopWithResult()).get() }
        stopped = true
      }
      try await fixture.waitForAdmissionToClose()
      #expect(!saved)
      if firstVideo {
        #expect(!stopped)
      } else {
        // Global-only captures cannot write this package and need not delay cancellation.
        try await stop.value
        #expect(stopped)
      }
      #expect(!fixture.isFinalized)
      // Cancelling the caller must not abandon an already admitted filesystem write.
      capture.cancel()
      release.signal()
      try await capture.value
      try await second.value
      try await stop.value
      #expect(saved)
      #expect(stopped)
      #expect(try fixture.globalScreenshots().count == 2)
      if firstVideo {
        #expect(fixture.isFinalized)
        #expect(try fixture.packageScreenshots().count == 2)
      } else {
        #expect(!FileManager.default.fileExists(atPath: fixture.package.path))
      }
      // Requests after completion remain global and cannot recreate the package.
      try await fixture.screenshot()
      #expect(try fixture.globalScreenshots().count == 3)
      #expect(try fixture.packageScreenshots().count == (firstVideo ? 2 : 0))
    }

    @Test(.timeLimit(.minutes(1)), arguments: Finish.allCases)
    func acceptedArchivePrecedesRealPackageFinalization(finishing: Finish) async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      try fixture.service.acceptFirstVideo(videoSample())
      fixture.service.appendMainAudioMix(try audioSample())
      #expect(fixture.service.hasAcceptedFirstVideo)
      #expect(fixture.service.recordingTimelineMilliseconds() != nil)
      fixture.session.state = .recording

      let release = fixture.blockArchives()
      defer { release.signal() }
      fixture.archive("accepted")
      let wroteBeforeFinalization = fixture.observeArchiveBeforeFinalization()
      var finished = false
      let completion = Task {
        let result =
          finishing == .stop
          ? await fixture.session.stopWithResult() : await fixture.session.pauseWithResult()
        finished = true
        return result
      }
      try await fixture.waitForAdmissionToClose()
      var joiningStarted = false
      var joined = false
      let joining =
        finishing == .pauseThenStop
        ? Task {
          joiningStarted = true
          let result = await fixture.session.stopWithResult()
          joined = true
          return result
        } : nil
      if joining != nil {
        while !joiningStarted {
          try Task.checkCancellation()
          await Task.yield()
        }
      }
      #expect(!finished)
      #expect(!joined)
      #expect(fixture.session.state == (finishing == .stop ? .stopping : .pausing))
      #expect(!fixture.isFinalized)
      #expect(!fixture.hasArchives)
      #expect(fixture.runtime.visionArchivePackageURL == nil)
      #expect(fixture.runtime.visionArchiveTimelineProvider == nil)
      // The runtime's inference callback resolves the current handler on MainActor.
      fixture.archive("late-during-shutdown")
      release.signal()
      try (await completion.value).get()
      if let joining { try (await joining.value).get() }

      #expect(wroteBeforeFinalization.written.withLock { $0 })
      #expect(fixture.session.state == (finishing == .pause ? .paused : .idle))
      let package = try RecordingPackage(contentsOf: fixture.package)
      #expect(package.isFinalized)
      #expect(try Data(contentsOf: package.mainMediaURL).count > 0)
      let metadata = try fixture.archiveMetadata()
      #expect(metadata["output"] == "accepted")
      #expect(metadata["visionID"] == "41")
      #expect(metadata["recordingTimelineMilliseconds"].flatMap(UInt64.init) != nil)
      fixture.archive("late-after-shutdown")
      await fixture.drainArchives()
      #expect(try fixture.archiveMetadata() == metadata)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationBeforeFirstVideoDrainsThenDeletesRealPackage() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      fixture.session.state = .starting
      #expect(!fixture.service.hasAcceptedFirstVideo)
      #expect(fixture.service.recordingTimelineMilliseconds() == nil)
      let release = fixture.blockArchives()
      defer { release.signal() }
      fixture.archive("accepted")
      let wroteBeforeCancellation = fixture.observeArchiveBeforeFinalization()
      var finished = false
      let completion = Task {
        let result = await fixture.session.stopWithResult()
        finished = true
        return result
      }
      try await fixture.waitForAdmissionToClose()
      #expect(!finished)
      #expect(fixture.session.state == .stopping)
      #expect(!fixture.hasArchives)
      fixture.archive("late-during-cancel")
      release.signal()
      try (await completion.value).get()
      #expect(wroteBeforeCancellation.written.withLock { $0 })
      #expect(fixture.session.state == .idle)
      #expect(!FileManager.default.fileExists(atPath: fixture.package.path))
      fixture.archive("late-after-cancel")
      // A barrier after completion proves accepted work cannot recreate the package.
      await fixture.drainArchives()
      #expect(!FileManager.default.fileExists(atPath: fixture.package.path))
      #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    @Test(arguments: [false, true])
    func screenshotsBeforePackageReadinessRemainStandalone(recording: Bool) async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      fixture.session.state = recording ? .recording : .starting
      try await fixture.screenshot()
      #expect(try fixture.globalScreenshots().count == 1)
      #expect(!FileManager.default.fileExists(atPath: fixture.package.path))
      // A standalone screenshot must not reserve the future recording's directory.
      try fixture.service.acceptFirstVideo(videoSample())
      fixture.service.appendMainAudioMix(try audioSample())
      fixture.session.state = .recording
      try await fixture.screenshot()
      #expect(try fixture.packageScreenshots().count == 1)
      try (await fixture.session.stopWithResult()).get()
      #expect(fixture.isFinalized)
    }

    @Test(arguments: InactiveScreenshotState.allCases)
    func readyPackageRejectsScreenshotsOutsideRecording(state: InactiveScreenshotState)
      async throws
    {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      try fixture.service.acceptFirstVideo(videoSample())
      fixture.service.appendMainAudioMix(try audioSample())
      fixture.session.state = state.state
      try await fixture.screenshot()
      #expect(try fixture.globalScreenshots().count == 1)
      #expect(try fixture.packageScreenshots().isEmpty)
      fixture.session.state = .recording
      try (await fixture.session.stopWithResult()).get()
    }

    @Test(.timeLimit(.minutes(1)), arguments: Finish.allCases)
    func screenshotsCloseAdmissionBeforeFinalization(finishing: Finish) async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      try fixture.service.acceptFirstVideo(videoSample())
      fixture.service.appendMainAudioMix(try audioSample())
      fixture.session.state = .recording
      try await fixture.screenshot()
      let accepted = try fixture.packageScreenshots()
      #expect(accepted.count == 1)
      let acceptedData = try Data(contentsOf: #require(accepted.first))
      var capturedAtBoundary = false
      fixture.session.stateDidChange = { state in
        guard state == .pausing || state == .stopping else { return }
        // This runs before the finishing task can clear handlers or suspend.
        #expect(fixture.runtime.visionArchiveHandler != nil)
        Task {
          do { try await fixture.screenshot() } catch { Issue.record(error) }
        }
        capturedAtBoundary = true
      }
      let release = fixture.blockArchives()
      defer { release.signal() }
      let completion = Task {
        finishing == .stop
          ? await fixture.session.stopWithResult() : await fixture.session.pauseWithResult()
      }
      try await fixture.waitForAdmissionToClose()
      #expect(capturedAtBoundary)
      #expect(fixture.session.isLocalRecording)
      #expect(!fixture.isFinalized)
      try await fixture.screenshot()
      #expect(try fixture.packageScreenshots() == accepted)
      release.signal()
      try (await completion.value).get()
      if finishing == .pauseThenStop { try (await fixture.session.stopWithResult()).get() }
      #expect(fixture.isFinalized)
      try await fixture.screenshot()
      #expect(try fixture.globalScreenshots().count == 4)
      #expect(try fixture.packageScreenshots() == accepted)
      #expect(try Data(contentsOf: #require(accepted.first)) == acceptedData)
    }

    @Test(.timeLimit(.minutes(1)))
    func screenshotsDuringCancellationCannotCreateOrRecreatePackage() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      fixture.session.state = .starting
      let release = fixture.blockArchives()
      defer { release.signal() }
      let completion = Task { await fixture.session.stopWithResult() }
      try await fixture.waitForAdmissionToClose()
      try await fixture.screenshot()
      #expect(!FileManager.default.fileExists(atPath: fixture.package.path))
      release.signal()
      try (await completion.value).get()
      try await fixture.screenshot()
      #expect(try fixture.globalScreenshots().count == 2)
      #expect(!FileManager.default.fileExists(atPath: fixture.package.path))
    }

    @Test
    func screenshotsRejectServiceAlreadyFinalizing() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      try fixture.service.acceptFirstVideo(videoSample())
      fixture.service.appendMainAudioMix(try audioSample())
      fixture.session.state = .recording
      var finished = false
      fixture.service.stop { _ in finished = true }
      // Service admission closes synchronously, before the completion callback.
      try await fixture.screenshot()
      #expect(try fixture.packageScreenshots().isEmpty)
      while !finished { await Task.yield() }
      #expect(fixture.isFinalized)
      try await fixture.screenshot()
      #expect(try fixture.packageScreenshots().isEmpty)
      #expect(try fixture.globalScreenshots().count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func initiatingFailureWithoutCleanupFailureRetainsTypedError() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      fixture.session.state = .starting
      let primary = NSError(
        domain: NSCocoaErrorDomain, code: 640,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 28)])
      let release = fixture.blockArchives()
      defer { release.signal() }
      let failure = Task { await fixture.session.fail(primary) }
      try await fixture.waitForAdmissionToClose()
      var joined = false
      let stop = Task {
        joined = true
        return await fixture.session.stopWithResult()
      }
      while !joined { await Task.yield() }
      release.signal()
      await failure.value
      guard case .failure(let returned) = await stop.value else {
        Issue.record("The initiating error must be returned even when cleanup succeeds")
        return
      }
      #expect(returned === primary)
      #expect((returned.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == 28)
      #expect(fixture.session.outputFailures.secondary.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: fixture.package.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func initiatingFailureSurvivesRealArchiveFailure() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      try fixture.service.acceptFirstVideo(videoSample())
      fixture.service.appendMainAudioMix(try audioSample())
      fixture.session.state = .recording
      // A conflicting file injects an archive error without exhausting the disk.
      try Data().write(to: fixture.package.appendingPathComponent("Visions"))
      fixture.archive("test archive")
      let primary = NSError(domain: "test.output", code: 94)
      await fixture.session.fail(primary)
      #expect(fixture.session.state == .failed(primary.localizedDescription))
      #expect(fixture.session.outputFailures.primary === primary)
      #expect(fixture.session.outputFailures.secondary.map(\.phase) == [.visionArchive])
      #expect(fixture.isFinalized)
    }

    @Test(.timeLimit(.minutes(1)))
    func initiatingFailureSurvivesLaterCallbacksAndRealFinalizationFailure() async throws {
      let fixture = try Fixture(recordingFailureHandler: { _ in })
      defer { fixture.cleanup() }
      // A video with no Main Mix deterministically fails real finalization.
      try fixture.service.acceptFirstVideo(videoSample())
      fixture.session.state = .recording
      let primary = NSError(
        domain: NSCocoaErrorDomain, code: 640,
        userInfo: [NSLocalizedDescriptionKey: "Injected disk-full output failure"])
      let later = NSError(domain: "test.delivery", code: 91)
      let youtube = NSError(domain: "test.youtube.finish", code: 92)
      let release = fixture.blockArchives()
      defer { release.signal() }
      let failure = Task { await fixture.session.fail(primary) }
      try await fixture.waitForAdmissionToClose()
      var joined = false
      let stop = Task {
        joined = true
        return await fixture.session.stopWithResult()
      }
      while !joined { await Task.yield() }
      await fixture.session.fail(later)
      await fixture.session.finishYouTubeOutput { .failure(youtube) }
      release.signal()
      await failure.value
      let result = await stop.value
      guard case .failure(let returned) = result else {
        Issue.record("Joined stop must report the initiating failure")
        return
      }
      #expect(returned === primary)
      #expect(fixture.session.state == .failed(primary.localizedDescription))
      #expect(fixture.session.outputFailures.primary === primary)
      let secondary = fixture.session.outputFailures.secondary
      #expect(secondary.map(\.phase) == [.output, .youtubeFinalization, .recordingFinalization])
      #expect(secondary[0].error === later)
      #expect(secondary[1].error === youtube)
      #expect(!fixture.isFinalized)
      // Historical recording errors must not permanently prevent Workspace shutdown.
      try (await fixture.session.stopWithResult()).get()
      #expect(fixture.session.outputFailures.primary === primary)
      // A new start attempt resets history even if its configuration is invalid.
      _ = await fixture.session.startWithResult()
      #expect(fixture.session.outputFailures.primary == nil)
      #expect(fixture.session.outputFailures.secondary.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func firstCleanupFailureBecomesPrimary(pausing: Bool) async throws {
      let fixture = try Fixture(recordingFailureHandler: { _ in })
      defer { fixture.cleanup() }
      try fixture.service.acceptFirstVideo(videoSample())
      fixture.session.state = .recording
      let result =
        pausing ? await fixture.session.pauseWithResult() : await fixture.session.stopWithResult()
      guard case .failure(let error) = result else {
        Issue.record("Missing Main Mix must fail finalization")
        return
      }
      #expect(fixture.session.outputFailures.primary === error)
      #expect(fixture.session.outputFailures.secondary.isEmpty)
      #expect(fixture.session.state == .failed(error.localizedDescription))
      #expect(!fixture.isFinalized)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func youtubeCleanupFailureSurvivesLaterRecordingFailure(pausing: Bool) async throws {
      let fixture = try Fixture(recordingFailureHandler: { _ in })
      defer { fixture.cleanup() }
      try fixture.service.acceptFirstVideo(videoSample())
      fixture.session.state = .recording
      let primary = NSError(domain: "test.youtube.finish", code: 93)
      let release = fixture.blockArchives()
      defer { release.signal() }
      let finish = Task {
        pausing ? await fixture.session.pauseWithResult() : await fixture.session.stopWithResult()
      }
      try await fixture.waitForAdmissionToClose()
      await fixture.session.finishYouTubeOutput { .failure(primary) }
      release.signal()
      guard case .failure(let returned) = await finish.value else {
        Issue.record("Expected YouTube cleanup failure")
        return
      }
      #expect(returned === primary)
      #expect(fixture.session.state == .failed(primary.localizedDescription))
      #expect(fixture.session.outputFailures.secondary.map(\.phase) == [.recordingFinalization])
    }

    @MainActor private final class Fixture {
      let root: URL
      let runtime: WorkspaceWindowRuntime
      let session: WorkspaceV4RecordingSession
      let service: SessionRecordService
      let screenshotQueue = DispatchQueue(label: "test.screenshot-worker")
      let queue = DispatchQueue(label: "test.workspace-vision-archive-lifecycle")
      var package: URL { service.packageDirectory }
      var hasArchives: Bool {
        FileManager.default.fileExists(atPath: package.appendingPathComponent("Visions").path)
      }
      var isFinalized: Bool {
        FileManager.default.fileExists(
          atPath: package.appendingPathComponent(RecordingPackage.finalizedMarkerFileName).path)
      }

      init(
        recordsPortrait: Bool = false,
        cutBoundaryTimeout: Duration = .seconds(10),
        screenCaptureService: ScreenCaptureService? = nil,
        recordingFailureHandler: @escaping @MainActor (any Error) -> Void = {
          Issue.record("Unexpected recording failure: \($0)")
        }
      ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var workspace = WorkspaceV4Bundle(definition: .init(), preferences: .init())
        let persistence = WorkspaceV4PersistenceCoordinator(
          workspaceSnapshot: { workspace }, replaceWorkspace: { workspace = $0 })
        let capture = WorkspaceCaptureSessionCoordinator(
          captureServiceFactory: { preconditionFailure("No camera expected") },
          audioCaptureServiceFactory: { preconditionFailure("No microphone expected") })
        runtime = WorkspaceWindowRuntime(
          persistence: persistence, captureSessionCoordinator: capture)
        session = WorkspaceV4RecordingSession(
          windowRuntime: runtime,
          screenCaptureService: screenCaptureService
            ?? ScreenCaptureService(captureQueue: screenshotQueue),
          visionArchiveQueue: queue, cutBoundaryTimeout: cutBoundaryTimeout)
        service = try SessionRecordService(
          baseDirectory: root, recordID: "archive-lifecycle",
          writerConfiguration: SegmentedMP4WriterConfiguration(
            width: 16, height: 16, frameRate: 30, videoBitRate: 100_000),
          audioTracks: [], recordsPortrait: recordsPortrait, failureHandler: recordingFailureHandler
        )
        try service.start()
        session.adoptStartedRecordingService(service)
      }

      func screenshot() async throws {
        var buffer: CVPixelBuffer?
        #expect(
          CVPixelBufferCreate(
            kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            == kCVReturnSuccess)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(
          CVPixelBufferGetBaseAddress(pixelBuffer), 0,
          CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let screenshots = try await session.captureScreenshots(
          sources: [.init(name: "Landscape", pixelBuffer: pixelBuffer, programCanvas: .landscape)],
          capturedAt: Date(timeIntervalSince1970: 1),
          globalDirectory: root.appendingPathComponent("global"))
        #expect(screenshots.count == 1)
        #expect(
          screenshots.first?.url.deletingLastPathComponent()
            == root.appendingPathComponent("global"))
      }

      func globalScreenshots() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
          at: root.appendingPathComponent("global"), includingPropertiesForKeys: nil)
      }

      func packageScreenshots() throws -> [URL] {
        let directory = package.appendingPathComponent("Screenshots")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil)
      }

      func cleanup() {
        session.stateDidChange = nil
        runtime.shutdown()
        try? FileManager.default.removeItem(at: root)
      }

      func blockArchives() -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        queue.async { _ = release.wait(timeout: .now() + 10) }
        return release
      }

      func archive(_ output: String) {
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
          .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        runtime.visionArchiveHandler?(41, image, output)
      }

      func observeArchiveBeforeFinalization() -> WorkspaceArchiveObservation {
        let observed = WorkspaceArchiveObservation()
        let directory = package.appendingPathComponent("Visions")
        let finalized = package.appendingPathComponent(RecordingPackage.finalizedMarkerFileName)
        queue.async {
          let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
          observed.written.withLock {
            $0 = files.count == 2 && !FileManager.default.fileExists(atPath: finalized.path)
          }
        }
        return observed
      }

      func waitForAdmissionToClose() async throws {
        while runtime.visionArchiveHandler != nil {
          try Task.checkCancellation()
          await Task.yield()
        }
      }

      func drainArchives() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
      }

      func archiveMetadata() throws -> [String: String] {
        let files = try FileManager.default.contentsOfDirectory(
          at: package.appendingPathComponent("Visions"), includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        let metadata = try #require(files.first { $0.pathExtension == "json" })
        return try #require(
          JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: String])
      }
    }

    private func videoSample() throws -> CMSampleBuffer {
      // Software-generated 16x16 black IDR (libx264 baseline); no encoder runs in this test.
      let sps: [UInt8] = [
        0x67, 0x42, 0xc0, 0x0a, 0xdd, 0xec, 0x04, 0x40, 0, 0, 3, 0, 0x40, 0, 0, 0x0f, 3, 0xc4, 0x89,
        0xe0,
      ]
      let pps: [UInt8] = [0x68, 0xce, 0x0f, 0x2c, 0x80]
      let idr: [UInt8] = [0x65, 0x88, 0x84, 0x04, 0xbc, 0x98, 0xa0, 0, 0x38, 0xa3, 0x80]
      var format: CMFormatDescription?
      let status = sps.withUnsafeBufferPointer { sps in
        pps.withUnsafeBufferPointer { pps in
          let pointers = [sps.baseAddress!, pps.baseAddress!]
          let sizes = [sps.count, pps.count]
          return CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: 2,
            parameterSetPointers: pointers, parameterSetSizes: sizes,
            nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
      }
      #expect(status == noErr)
      var size = idr.count + 4
      let block = try dataBlock(Data([0, 0, 0, UInt8(idr.count)] + idr))
      var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid)
      var sample: CMSampleBuffer?
      #expect(
        CMSampleBufferCreateReady(
          allocator: kCFAllocatorDefault, dataBuffer: block,
          formatDescription: try #require(format),
          sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
          sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr)
      return try #require(sample)
    }

    private func audioSample(frameCount: Int = 4800) throws -> CMSampleBuffer {
      var stream = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
      var format: CMAudioFormatDescription?
      #expect(
        CMAudioFormatDescriptionCreate(
          allocator: kCFAllocatorDefault, asbd: &stream, layoutSize: 0, layout: nil,
          magicCookieSize: 0, magicCookie: nil, extensions: nil,
          formatDescriptionOut: &format) == noErr)
      var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid)
      var sample: CMSampleBuffer?
      #expect(
        CMSampleBufferCreateReady(
          allocator: kCFAllocatorDefault, dataBuffer: try dataBlock(Data(count: frameCount * 8)),
          formatDescription: try #require(format), sampleCount: frameCount,
          sampleTimingEntryCount: 1, sampleTimingArray: &timing,
          sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
      return try #require(sample)
    }

    private func dataBlock(_ data: Data) throws -> CMBlockBuffer {
      var block: CMBlockBuffer?
      #expect(
        CMBlockBufferCreateWithMemoryBlock(
          allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
          blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
          dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr)
      let buffer = try #require(block)
      #expect(
        data.withUnsafeBytes {
          CMBlockBufferReplaceDataBytes(
            with: $0.baseAddress!, blockBuffer: buffer, offsetIntoDestination: 0,
            dataLength: data.count)
        } == noErr)
      return buffer
    }
  }
}

private final class WorkspaceArchiveObservation: Sendable {
  let written = Mutex(false)
}

private final class OtherWorkspaceBlockingFileManager: FileManager, @unchecked Sendable {
  let started = Mutex(false)
  let unblocked = Mutex(false)
  let release = DispatchSemaphore(value: 0)
  override func createDirectory(
    at url: URL, withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil
  ) throws {
    let first = started.withLock { value in
      let first = !value
      value = true
      return first
    }
    if first {
      _ = release.wait(timeout: .now() + 15)
      unblocked.withLock { $0 = true }
    }
    try super.createDirectory(
      at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
  }
}
