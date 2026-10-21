// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreImage
import CoreMedia
import Foundation
import LDTXMP4
@testable import LDTXProgramRuntime
import LDTXRecordBundleFormat
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceBundleFormat
import Synchronization
import Testing

extension OutputTestSuite {
  @MainActor
  @Suite struct WorkspaceVisionArchiveLifecycleIntegrationTestSuite {
    enum Finish: CaseIterable { case stop, pause, pauseThenStop }

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

    @MainActor private final class Fixture {
      let root: URL
      let runtime: WorkspaceWindowRuntime
      let session: WorkspaceV4RecordingSession
      let service: SessionRecordService
      let queue = DispatchQueue(label: "test.workspace-vision-archive-lifecycle")
      var package: URL { service.packageDirectory }
      var hasArchives: Bool {
        FileManager.default.fileExists(atPath: package.appendingPathComponent("Visions").path)
      }
      var isFinalized: Bool {
        FileManager.default.fileExists(
          atPath: package.appendingPathComponent(RecordingPackage.finalizedMarkerFileName).path)
      }

      init() throws {
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
        session = WorkspaceV4RecordingSession(windowRuntime: runtime, visionArchiveQueue: queue)
        service = try SessionRecordService(
          baseDirectory: root, recordID: "archive-lifecycle",
          writerConfiguration: SegmentedMP4WriterConfiguration(
            width: 16, height: 16, frameRate: 30, videoBitRate: 100_000),
          audioTracks: [], failureHandler: { Issue.record("Unexpected recording failure: \($0)") })
        try service.start()
        session.adoptStartedRecordingService(service)
      }

      func cleanup() {
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

    private func audioSample() throws -> CMSampleBuffer {
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
          allocator: kCFAllocatorDefault, dataBuffer: try dataBlock(Data(count: 4_800 * 8)),
          formatDescription: try #require(format), sampleCount: 4_800,
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
