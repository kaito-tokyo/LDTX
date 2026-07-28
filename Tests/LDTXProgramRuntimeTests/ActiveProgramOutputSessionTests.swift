// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXCapture
import LDTXDash
import LDTXMP4
import LDTXProgram
import LDTXProgramRendering
import LDTXRecording
import XCTest

@testable import LDTXProgramRuntime

@MainActor
final class ActiveProgramOutputSessionTests: XCTestCase {
  func testSessionKeepsInjectedDiagnosticIdentifier() {
    let id = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let session = ActiveProgramOutputSession(
      id: id,
      currentProgramRuntime: makeProgramRuntime(),
      mediaHub: ProgramOutputMediaHub()
    )

    XCTAssertEqual(session.id, id)
  }

  func testStartRequiresTheSharedProgramState() async {
    let session = ActiveProgramOutputSession(
      currentProgramRuntime: makeProgramRuntime(),
      mediaHub: ProgramOutputMediaHub()
    )
    let rejected = expectation(description: "start rejected")

    session.start(
      programPreferences: ProgramPreferences(),
      audioDeviceIDsByInputKey: [:],
      eventHandler: { _ in },
      failureHandler: { _ in },
      completionHandler: { result in
        guard case .failure(let error as ActiveProgramOutputSessionError) = result,
          case .missingProgramConfiguration = error
        else {
          XCTFail("Expected a missing shared Program configuration error")
          rejected.fulfill()
          return
        }
        rejected.fulfill()
      }
    )

    await fulfillment(of: [rejected], timeout: 1)
  }

  func testProgramPreferencesUpdateMainMixerDuringStartAndWhileRunning() async {
    let mixer = ProgramMainAudioMixerSpy()
    let channel = ProgramAudioChannel(component: .silentAudio)
    let runtime = makeProgramRuntime()
    runtime.updateProgram(Self.outputConfiguration(audioChannels: [channel]))
    let session = ActiveProgramOutputSession(
      currentProgramRuntime: runtime,
      mediaHub: ProgramOutputMediaHub(),
      audioMixer: mixer
    )
    let started = expectation(description: "output started")
    session.start(
      programPreferences: ProgramPreferences(),
      audioDeviceIDsByInputKey: [:],
      eventHandler: { _ in },
      failureHandler: { error in XCTFail("Unexpected output failure: \(error)") },
      completionHandler: { result in
        if case .failure(let error) = result { XCTFail("Unexpected start failure: \(error)") }
        started.fulfill()
      }
    )
    let mutedDuringStart = ProgramPreferences(audioChannelGainsByName: [channel.name: 0])
    session.updateProgramPreferences(mutedDuringStart)

    mixer.completeStart()
    await fulfillment(of: [started], timeout: 2)
    XCTAssertEqual(mixer.gainUpdates.last, mutedDuringStart)

    let runningPreferences = ProgramPreferences(audioChannelGainsByName: [channel.name: 0.5])
    session.updateProgramPreferences(runningPreferences)
    XCTAssertEqual(mixer.gainUpdates.last, runningPreferences)

    await withCheckedContinuation { continuation in
      session.stop { continuation.resume() }
    }
  }

  func testSwitchProgramRuntimeTransfersClockUpdateRegistration() async {
    let firstUpdates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let secondUpdates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let firstRuntime = makeProgramRuntime(lowFrequencyUpdateRegistry: firstUpdates)
    let secondRuntime = makeProgramRuntime(lowFrequencyUpdateRegistry: secondUpdates)
    firstRuntime.updateProgram(Self.clockOutputConfiguration())
    secondRuntime.updateProgram(Self.clockOutputConfiguration())
    let mixer = ProgramMainAudioMixerSpy()
    let session = ActiveProgramOutputSession(
      currentProgramRuntime: firstRuntime,
      mediaHub: ProgramOutputMediaHub(),
      audioMixer: mixer
    )
    let started = expectation(description: "output started")
    session.start(
      programPreferences: ProgramPreferences(),
      audioDeviceIDsByInputKey: [:],
      eventHandler: { _ in },
      failureHandler: { error in XCTFail("Unexpected output failure: \(error)") },
      completionHandler: { result in
        if case .failure(let error) = result { XCTFail("Unexpected start failure: \(error)") }
        started.fulfill()
      }
    )
    mixer.completeStart()
    await fulfillment(of: [started], timeout: 2)

    let firstClockActivated = await waitUntil {
      firstUpdates.registrationCountForTesting == 1
    }
    XCTAssertTrue(firstClockActivated)
    XCTAssertEqual(secondUpdates.registrationCountForTesting, 0)

    XCTAssertTrue(session.switchProgramRuntime(to: secondRuntime))
    let handoffCompleted = await waitUntil {
      firstUpdates.registrationCountForTesting == 0
        && secondUpdates.registrationCountForTesting == 1
    }
    XCTAssertTrue(handoffCompleted)

    await withCheckedContinuation { continuation in
      session.stop { continuation.resume() }
    }
    let secondClockDeactivated = await waitUntil {
      secondUpdates.registrationCountForTesting == 0
    }
    XCTAssertTrue(secondClockDeactivated)
  }

  func testUnavailableRecordingAudioTrackIsPresentedAsAFlowInterruption() {
    let error = ProgramOutputFlowInterruptionError.recordingAudioTrackUnavailable("Desk Mic")

    XCTAssertEqual(error.errorDialogKind, .recordingAudioTrackUnavailable)
    XCTAssertEqual(
      error.localizedDescription,
      "The recording audio track could not be started: Desk Mic"
    )
  }

  func testWorkspaceMediaHubDeliversSameSampleToIndependentServices() throws {
    let recording = SampleBufferSpy()
    let service = SampleBufferSpy()
    let hub = ProgramOutputMediaHub()
    _ = hub.subscribe(mainVideo: recording.receive, mainAudioMix: { _ in })
    _ = hub.subscribe(mainVideo: service.receive, mainAudioMix: { _ in })
    var createdSampleBuffer: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: nil,
        sampleCount: 0,
        sampleTimingEntryCount: 0,
        sampleTimingArray: nil,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &createdSampleBuffer),
      noErr)
    let sampleBuffer = try XCTUnwrap(createdSampleBuffer)

    hub.publishMainVideo(sampleBuffer)

    XCTAssertTrue(recording.sampleBuffer === sampleBuffer)
    XCTAssertTrue(service.sampleBuffer === sampleBuffer)
  }

  func testWorkspaceMediaHubBroadcastsOutputStopBoundaryToSubscribers() {
    let first = CallbackSpy()
    let removed = CallbackSpy()
    let hub = ProgramOutputMediaHub()
    _ = hub.subscribe(
      mainVideo: { _ in }, mainAudioMix: { _ in }, outputWillStop: first.receive)
    let removedSubscription = hub.subscribe(
      mainVideo: { _ in }, mainAudioMix: { _ in }, outputWillStop: removed.receive)
    hub.unsubscribe(removedSubscription)

    hub.publishOutputWillStop()

    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(removed.count, 0)
  }

  func testMonitorOnlyConfiguresSampleConsumptionAndDoesNotOpenCaptureDevice() async {
    let channel = ProgramAudioChannel(
      component: .inputAudioDevice(InputAudioDeviceComponent()))
    let channels = [channel]
    let monitor = ProgramAudioMonitor()
    let started = expectation(description: "monitor configured")
    let resultSpy = ResultSpy()

    monitor.restart(
      audioChannels: channels,
      inputAudioDeviceMappings: [channels.inputAudioDeviceMappingKey(for: channel): "not-a-device"],
      programPreferences: ProgramPreferences(),
      inputPassthroughChannelKeys: [],
      peakMeter: ProgramAudioPeakMeter(),
      completionHandler: { result in
        resultSpy.receive(result)
        started.fulfill()
      })

    await fulfillment(of: [started], timeout: 1)
    XCTAssertTrue(resultSpy.succeeded)
    await withCheckedContinuation { continuation in
      monitor.stop { continuation.resume() }
    }
  }

  func testStopWhileStartingCompletesStartExactlyOnce() async {
    let runtime = makeProgramRuntime()
    runtime.updateProgram(Self.outputConfiguration())
    let session = ActiveProgramOutputSession(
      currentProgramRuntime: runtime,
      mediaHub: ProgramOutputMediaHub())
    let startCompleted = expectation(description: "start completed")
    let stopCompleted = expectation(description: "stop completed")
    var startCompletionCount = 0
    var startError: Error?

    session.start(
      programPreferences: ProgramPreferences(),
      audioDeviceIDsByInputKey: [:],
      eventHandler: { _ in },
      failureHandler: { _ in },
      completionHandler: { result in
        startCompletionCount += 1
        if case .failure(let error) = result { startError = error }
        startCompleted.fulfill()
      })

    session.stop { stopCompleted.fulfill() }

    await fulfillment(of: [startCompleted, stopCompleted], timeout: 2)
    try? await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(startCompletionCount, 1)
    XCTAssertTrue(startError is CancellationError)
  }

  func testStopBeforeStartMakesSessionTerminal() async {
    let session = ActiveProgramOutputSession(
      currentProgramRuntime: makeProgramRuntime(),
      mediaHub: ProgramOutputMediaHub())

    await withCheckedContinuation { continuation in
      session.stop { continuation.resume() }
    }

    let startRejected = expectation(description: "start rejected")
    session.start(
      programPreferences: ProgramPreferences(),
      audioDeviceIDsByInputKey: [:],
      eventHandler: { _ in },
      failureHandler: { _ in },
      completionHandler: { result in
        guard case .failure(let error) = result else {
          XCTFail("A stopped one-shot session must reject start")
          startRejected.fulfill()
          return
        }
        guard let sessionError = error as? ActiveProgramOutputSessionError,
          case .sessionAlreadyUsed = sessionError
        else {
          XCTFail("Unexpected start rejection: \(error)")
          startRejected.fulfill()
          return
        }
        startRejected.fulfill()
      })

    await fulfillment(of: [startRejected], timeout: 1)
  }

  func testAudioCaptureControllerStopWaitsForInFlightStartCleanup() async {
    let capture = DelayedAudioCaptureService()
    let captureStarted = expectation(description: "capture start requested")
    capture.startRequested = { captureStarted.fulfill() }
    let controller = ProgramAudioInputCaptureController(makeCaptureService: { capture })
    let channel = ProgramAudioChannel(
      component: .inputAudioDevice(InputAudioDeviceComponent()))
    let channels = [channel]
    let restartCompleted = expectation(description: "restart cancelled")

    controller.restart(
      audioChannels: channels,
      inputAudioDeviceMappings: [channels.inputAudioDeviceMappingKey(for: channel): "device"],
      failureHandler: { _ in },
      sampleHandler: { _, _, _ in },
      completionHandler: { result in
        guard case .failure(let error) = result, error is CancellationError else {
          XCTFail("The superseded start must finish as cancellation")
          restartCompleted.fulfill()
          return
        }
        restartCompleted.fulfill()
      })
    await fulfillment(of: [captureStarted], timeout: 1)

    let stopCompleted = expectation(description: "stop completed after start cleanup")
    let stopCompletionSpy = CallbackSpy()
    controller.stop {
      stopCompletionSpy.receive()
      stopCompleted.fulfill()
    }
    try? await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(capture.stopCount, 1)
    XCTAssertEqual(stopCompletionSpy.count, 0)
    XCTAssertFalse(capture.isActive)

    capture.completeStart()

    await fulfillment(of: [restartCompleted, stopCompleted], timeout: 1)
    XCTAssertEqual(capture.stopCount, 2)
    XCTAssertEqual(stopCompletionSpy.count, 1)
    XCTAssertFalse(capture.isActive)
  }

  func testRecordServiceStopWaitsForInFlightCaptureStartAndBecomesTerminal() async throws {
    let baseDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: baseDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let capture = DelayedAudioCaptureService()
    let captureStarted = expectation(description: "record capture start requested")
    capture.startRequested = { captureStarted.fulfill() }
    let service = try ProgramRecordService(
      baseDirectory: baseDirectory,
      recordID: "lifecycle-test",
      writerConfiguration: SegmentedMP4WriterConfiguration(
        width: 16, height: 16, frameRate: 30, videoBitRate: 100_000),
      audioTracks: [
        ProgramRecordAudioTrack(
          key: "input", deviceID: "device", trackID: "input",
          displayName: "Input", fileNameStem: "InputDevices/Input")
      ],
      failureHandler: { error in XCTFail("Unexpected record failure: \(error)") },
      makeCaptureService: { capture })
    let startCompleted = expectation(description: "record start cancelled")
    service.start { result in
      guard case .failure(let error) = result, error is CancellationError else {
        XCTFail("Record start must be cancelled by stop")
        startCompleted.fulfill()
        return
      }
      startCompleted.fulfill()
    }
    await fulfillment(of: [captureStarted], timeout: 1)

    let stopCompleted = expectation(description: "record stop completed")
    let stopCompletionSpy = CallbackSpy()
    service.stop {
      stopCompletionSpy.receive()
      stopCompleted.fulfill()
    }
    try? await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(stopCompletionSpy.count, 0)

    capture.completeStart()

    await fulfillment(of: [startCompleted, stopCompleted], timeout: 2)
    XCTAssertEqual(capture.stopCount, 2)
    XCTAssertEqual(stopCompletionSpy.count, 1)

    let rejected = expectation(description: "record restart rejected")
    service.start { result in
      guard case .failure(let error) = result,
        let serviceError = error as? ProgramRecordServiceError,
        case .alreadyStarted = serviceError
      else {
        XCTFail("Stopped record service must reject reuse")
        rejected.fulfill()
        return
      }
      rejected.fulfill()
    }
    await fulfillment(of: [rejected], timeout: 1)
  }

  func testRecordServiceRecordsOutputStoppedAfterTeardownCompletes() async throws {
    let baseDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: baseDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let service = try ProgramRecordService(
      baseDirectory: baseDirectory,
      recordID: "diagnostics-stop-order-test",
      writerConfiguration: SegmentedMP4WriterConfiguration(
        width: 16, height: 16, frameRate: 30, videoBitRate: 100_000),
      audioTracks: [],
      diagnosticsContext: RecordingDiagnosticsContext(
        launchID: UUID(), launchUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds),
      failureHandler: { error in XCTFail("Unexpected record failure: \(error)") },
      makeCaptureService: { DelayedAudioCaptureService() })

    let started = expectation(description: "record started")
    service.start { result in
      if case .failure(let error) = result { XCTFail("Unexpected start failure: \(error)") }
      started.fulfill()
    }
    await fulfillment(of: [started], timeout: 1)

    let stopped = expectation(description: "record stopped")
    service.stopPreservingIncompletePackage { stopped.fulfill() }
    XCTAssertEqual(
      try RecordingDiagnosticsEventLogReader.readCompleteEvents(from: service.packageDirectory)
        .map(\.kind),
      [.recordingStarted, .abnormalStop]
    )

    await fulfillment(of: [stopped], timeout: 2)
    XCTAssertEqual(
      try RecordingDiagnosticsEventLogReader.readCompleteEvents(from: service.packageDirectory)
        .map(\.kind),
      [.recordingStarted, .abnormalStop, .outputStopped]
    )
  }

  func testYouTubeServiceStopBeforeStartMakesServiceTerminal() async throws {
    let service = YouTubeOutputWorkspaceService(
      endpoint: DASHIngestEndpoint(
        baseURL: try XCTUnwrap(URL(string: "https://example.com/live/"))),
      configuration: ProgramRuntimeConfiguration(
        composite: CompositeProgramDefinition(),
        audioChannels: [],
        canvasWidth: 16,
        canvasHeight: 16,
        outputWidth: 16,
        outputHeight: 16,
        frameRate: 30,
        timeSeconds: 0,
        videoPTSMasterCameraID: nil,
        cameraIDsByInputKey: [:],
        cameraInputColorOverrides: [:],
        backgroundRemovalInputKeys: []),
      continuityStore: YouTubeOutputWorkspaceStateStore(),
      boundary: YouTubeOutputServiceProcessClient(),
      eventHandler: { _ in },
      failureHandler: { error in XCTFail("Unexpected YouTube failure: \(error)") })

    await withCheckedContinuation { continuation in
      service.stop { _ in continuation.resume() }
    }

    let rejected = expectation(description: "YouTube restart rejected")
    service.start { result in
      guard case .failure(let error) = result,
        let serviceError = error as? YouTubeOutputWorkspaceServiceError,
        case .alreadyStarted = serviceError
      else {
        XCTFail("Stopped YouTube service must reject reuse")
        rejected.fulfill()
        return
      }
      rejected.fulfill()
    }
    await fulfillment(of: [rejected], timeout: 1)
  }

  private func makeProgramRuntime(
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry = LowFrequencyUpdateRegistry(
      interval: .seconds(60)
    )
  ) -> ProgramRuntime {
    ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry
    )
  }

  private func waitUntil(
    timeout: TimeInterval = 2,
    condition: () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  private static func outputConfiguration(
    audioChannels: [ProgramAudioChannel] = []
  ) -> ProgramRuntimeConfiguration {
    ProgramRuntimeConfiguration(
      composite: CompositeProgramDefinition(),
      audioChannels: audioChannels,
      canvasWidth: 16,
      canvasHeight: 16,
      outputWidth: 16,
      outputHeight: 16,
      frameRate: 30,
      timeSeconds: 0,
      videoPTSMasterCameraID: nil,
      cameraIDsByInputKey: [:],
      cameraInputColorOverrides: [:],
      backgroundRemovalInputKeys: []
    )
  }

  private static func clockOutputConfiguration() -> ProgramRuntimeConfiguration {
    ProgramRuntimeConfiguration(
      composite: CompositeProgramDefinition(steps: [
        CompositeProgramStep(
          id: "clock",
          component: .clock(
            ClockComponent(
              destinationX: 0.1,
              destinationY: 0.1,
              destinationWidth: 0.8,
              destinationHeight: 0.4
            )))
      ]),
      audioChannels: [],
      canvasWidth: 320,
      canvasHeight: 180,
      outputWidth: 320,
      outputHeight: 180,
      frameRate: 30,
      timeSeconds: 0,
      videoPTSMasterCameraID: nil,
      cameraIDsByInputKey: [:],
      cameraInputColorOverrides: [:],
      backgroundRemovalInputKeys: []
    )
  }
}

private final class SampleBufferSpy: @unchecked Sendable {
  private let lock = NSLock()
  private var storedSampleBuffer: CMSampleBuffer?
  var sampleBuffer: CMSampleBuffer? { lock.withLock { storedSampleBuffer } }
  func receive(_ sampleBuffer: CMSampleBuffer) {
    lock.withLock { storedSampleBuffer = sampleBuffer }
  }
}

private final class ProgramMainAudioMixerSpy: ProgramMainAudioMixing, @unchecked Sendable {
  private let lock = NSLock()
  private var startCompletion: (@Sendable (Result<Void, any Error>) -> Void)?
  private var storedGainUpdates: [ProgramPreferences] = []

  var gainUpdates: [ProgramPreferences] { lock.withLock { storedGainUpdates } }

  func start(
    audioChannels _: [ProgramAudioChannel],
    inputAudioDeviceMappings _: [String: String],
    programPreferences _: ProgramPreferences,
    failureHandler _: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    lock.withLock { startCompletion = completionHandler }
  }

  func completeStart() {
    let completion = lock.withLock {
      let completion = startCompletion
      startCompletion = nil
      return completion
    }
    completion?(.success(()))
  }

  func addMainAudioMixHandler(_: @escaping @Sendable (CMSampleBuffer) -> Void) -> UUID { UUID() }
  func removeMainAudioMixHandler(id _: UUID) {}
  func updateGains(
    audioChannels _: [ProgramAudioChannel],
    programPreferences: ProgramPreferences
  ) {
    lock.withLock { storedGainUpdates.append(programPreferences) }
  }
  func noteVideoPresentationTime(_: CMTime) {}
  func stop(completionHandler: @escaping @Sendable () -> Void) { completionHandler() }
}

private final class CallbackSpy: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0
  var count: Int { lock.withLock { storedCount } }
  func receive() { lock.withLock { storedCount += 1 } }
}

private final class ResultSpy: @unchecked Sendable {
  private let lock = NSLock()
  private var storedSucceeded = false
  var succeeded: Bool { lock.withLock { storedSucceeded } }
  func receive(_ result: Result<Void, any Error>) {
    lock.withLock {
      if case .success = result { storedSucceeded = true }
    }
  }
}

private final class DelayedAudioCaptureService: ProgramAudioCaptureStreaming, @unchecked Sendable {
  private struct State {
    var completion: (@Sendable (Result<Void, any Error>) -> Void)?
    var isActive = false
    var stopCount = 0
  }

  private let lock = NSLock()
  private var state = State()
  var startRequested: (@Sendable () -> Void)?
  var isActive: Bool { lock.withLock { state.isActive } }
  var stopCount: Int { lock.withLock { state.stopCount } }

  func startAudioCapture(
    audioDeviceID: String?,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    handler: @escaping @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    _ = audioDeviceID
    _ = failureHandler
    _ = handler
    lock.withLock { state.completion = completionHandler }
    startRequested?()
  }

  func completeStart() {
    let completion = lock.withLock { () -> (@Sendable (Result<Void, any Error>) -> Void)? in
      state.isActive = true
      let completion = state.completion
      state.completion = nil
      return completion
    }
    completion?(.success(()))
  }

  func stop(completionHandler: @escaping @Sendable () -> Void) {
    lock.withLock {
      state.stopCount += 1
      state.isActive = false
    }
    completionHandler()
  }
}
