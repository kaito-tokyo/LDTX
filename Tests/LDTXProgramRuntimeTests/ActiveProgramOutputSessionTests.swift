// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
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
      mediaHub: ProgramOutputMediaHub(),
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator()
    )

    XCTAssertEqual(session.id, id)
  }

  func testStartRequiresTheSharedProgramState() async {
    let session = ActiveProgramOutputSession(
      currentProgramRuntime: makeProgramRuntime(),
      mediaHub: ProgramOutputMediaHub(),
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator()
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
    let didStartMixer = await waitUntil { mixer.isStartPending }
    XCTAssertTrue(didStartMixer)
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

  func testAudioOutputIsPublishedWithoutAGate() async throws {
    let mixer = ProgramMainAudioMixerSpy()
    let runtime = makeProgramRuntime()
    runtime.updateProgram(Self.outputConfiguration())
    let hub = ProgramOutputMediaHub()
    let deliveredAudio = CallbackSpy()
    let subscription = hub.subscribe(
      mainVideo: { _ in },
      mainAudioMix: { _ in deliveredAudio.receive() },
      outputWillStop: {}
    )
    defer { hub.unsubscribe(subscription) }
    let started = expectation(description: "output started")
    let session = ActiveProgramOutputSession(
      currentProgramRuntime: runtime,
      mediaHub: hub,
      audioMixer: mixer
    )

    session.start(
      programPreferences: ProgramPreferences(),
      audioDeviceIDsByInputKey: [:],
      eventHandler: { _ in },
      failureHandler: { error in XCTFail("Unexpected output failure: \(error)") },
      completionHandler: { result in
        guard case .success = result else {
          return XCTFail("Output session should start")
        }
        started.fulfill()
      }
    )
    let didStartMixer = await waitUntil { mixer.isStartPending }
    XCTAssertTrue(didStartMixer)
    mixer.completeStart()
    await fulfillment(of: [started], timeout: 1)
    mixer.emitMainAudioMix(try makeEmptySampleBuffer())
    let didDeliverAudio = await waitUntil { deliveredAudio.count == 1 }
    XCTAssertTrue(didDeliverAudio)

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
    let didStartMixer = await waitUntil { mixer.isStartPending }
    XCTAssertTrue(didStartMixer)
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

  func testWorkspaceMediaHubDeliversSameSampleToIndependentServices() async throws {
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

    let didDeliverToBothServices = await waitUntil {
      recording.sampleBuffer != nil && service.sampleBuffer != nil
    }
    XCTAssertTrue(didDeliverToBothServices)
    XCTAssertTrue(recording.sampleBuffer === sampleBuffer)
    XCTAssertTrue(service.sampleBuffer === sampleBuffer)
  }

  func testWorkspaceMediaHubBroadcastsOutputStopBoundaryToSubscribers() async {
    let first = CallbackSpy()
    let removed = CallbackSpy()
    let hub = ProgramOutputMediaHub()
    _ = hub.subscribe(
      mainVideo: { _ in }, mainAudioMix: { _ in }, outputWillStop: first.receive)
    let removedSubscription = hub.subscribe(
      mainVideo: { _ in }, mainAudioMix: { _ in }, outputWillStop: removed.receive)
    hub.unsubscribe(removedSubscription)

    hub.publishOutputWillStop()

    let didBroadcastStop = await waitUntil { first.count == 1 }
    XCTAssertTrue(didBroadcastStop)
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
      mediaHub: ProgramOutputMediaHub(),
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
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
      mediaHub: ProgramOutputMediaHub(),
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())

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

  func testWorkspaceAudioCaptureIsSharedAndConsumerUnsubscribeDoesNotStopIt() async {
    let capture = DelayedAudioCaptureService()
    let captureStarted = expectation(description: "capture start requested")
    capture.startRequested = { captureStarted.fulfill() }
    let coordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { CameraCaptureService() },
      audioCaptureServiceFactory: { capture })
    let firstStarted = expectation(description: "first consumer started")
    let secondStarted = expectation(description: "second consumer started")
    let first = coordinator.subscribeAudio(
      deviceID: "device", failureHandler: { _ in }, sampleHandler: { _ in },
      completionHandler: { _ in firstStarted.fulfill() })
    let second = coordinator.subscribeAudio(
      deviceID: "device", failureHandler: { _ in }, sampleHandler: { _ in },
      completionHandler: { _ in secondStarted.fulfill() })
    await fulfillment(of: [captureStarted], timeout: 1)
    XCTAssertEqual(capture.startCount, 1)
    capture.completeStart()
    await fulfillment(of: [firstStarted, secondStarted], timeout: 1)

    coordinator.unsubscribeAudio(first)
    coordinator.unsubscribeAudio(second)
    XCTAssertEqual(capture.stopCount, 0)
    XCTAssertTrue(capture.isActive)

    let workspaceStopped = expectation(description: "workspace capture stopped")
    coordinator.stopAndReset { workspaceStopped.fulfill() }
    await fulfillment(of: [workspaceStopped], timeout: 1)
    XCTAssertEqual(capture.stopCount, 1)
    XCTAssertFalse(capture.isActive)
  }

  func testWorkspaceAudioSubscribeDuringShutdownIsCancelledOnceWithoutCreatingCapture() async {
    let capture = DelayedAudioCaptureService()
    let coordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { CameraCaptureService() },
      audioCaptureServiceFactory: { capture })
    let firstStarted = expectation(description: "first capture start requested")
    capture.startRequested = { firstStarted.fulfill() }
    _ = coordinator.subscribeAudio(
      deviceID: "device", failureHandler: { _ in }, sampleHandler: { _ in },
      completionHandler: { _ in })
    await fulfillment(of: [firstStarted], timeout: 1)

    let stopped = expectation(description: "workspace stopped")
    coordinator.stopAndReset { stopped.fulfill() }
    let rejected = expectation(description: "shutdown subscription rejected once")
    rejected.expectedFulfillmentCount = 1
    _ = coordinator.subscribeAudio(
      deviceID: "other", failureHandler: { _ in }, sampleHandler: { _ in },
      completionHandler: { result in
        guard case .failure(let error) = result, error is CancellationError else {
          XCTFail("Shutdown subscription must receive CancellationError")
          return
        }
        rejected.fulfill()
      })
    XCTAssertEqual(capture.startCount, 1)
    capture.completeStart()
    await fulfillment(of: [rejected, stopped], timeout: 1)
    XCTAssertEqual(capture.stopCount, 2)
    XCTAssertFalse(capture.isActive)
  }

  func testWorkspaceAudioUnsubscribeWhileStartingDoesNotStopCapture() async {
    let capture = DelayedAudioCaptureService()
    let startRequested = expectation(description: "capture start requested")
    capture.startRequested = { startRequested.fulfill() }
    let coordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { CameraCaptureService() },
      audioCaptureServiceFactory: { capture })
    let completed = expectation(description: "start completion delivered once")
    completed.expectedFulfillmentCount = 1
    let subscription = coordinator.subscribeAudio(
      deviceID: "device", failureHandler: { _ in }, sampleHandler: { _ in },
      completionHandler: { _ in completed.fulfill() })
    await fulfillment(of: [startRequested], timeout: 1)

    coordinator.unsubscribeAudio(subscription)
    XCTAssertEqual(capture.stopCount, 0)
    capture.completeStart()
    await fulfillment(of: [completed], timeout: 1)
    XCTAssertTrue(capture.isActive)

    let stopped = expectation(description: "workspace stopped")
    coordinator.stopAndReset { stopped.fulfill() }
    await fulfillment(of: [stopped], timeout: 1)
    XCTAssertEqual(capture.stopCount, 1)
  }

  func testWorkspaceAudioStartFailureCompletesEverySubscriberOnce() async {
    let capture = DelayedAudioCaptureService()
    let coordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { CameraCaptureService() },
      audioCaptureServiceFactory: { capture })
    let first = expectation(description: "first completion")
    let second = expectation(description: "second completion")
    first.expectedFulfillmentCount = 1
    second.expectedFulfillmentCount = 1
    _ = coordinator.subscribeAudio(
      deviceID: "device", failureHandler: { _ in }, sampleHandler: { _ in },
      completionHandler: { result in
        if case .success = result { XCTFail("Expected start failure") }
        first.fulfill()
      })
    _ = coordinator.subscribeAudio(
      deviceID: "device", failureHandler: { _ in }, sampleHandler: { _ in },
      completionHandler: { result in
        if case .success = result { XCTFail("Expected start failure") }
        second.fulfill()
      })

    capture.failStart(FakeAudioCaptureError.expected)
    await fulfillment(of: [first, second], timeout: 1)
    XCTAssertEqual(capture.startCount, 1)
    XCTAssertFalse(capture.isActive)

    let stopped = expectation(description: "workspace stopped")
    coordinator.stopAndReset { stopped.fulfill() }
    await fulfillment(of: [stopped], timeout: 1)
    XCTAssertEqual(capture.stopCount, 1)
  }

  func testWorkspaceAudioStartFailureRetiresSubscribersBeforeRetry() async throws {
    let capture = DelayedAudioCaptureService()
    let coordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { CameraCaptureService() },
      audioCaptureServiceFactory: { capture })
    let failedStart = expectation(description: "first start failure")
    let retiredSubscriberReceivedSample = expectation(description: "retired subscriber sample")
    retiredSubscriberReceivedSample.isInverted = true
    _ = coordinator.subscribeAudio(
      deviceID: "device",
      failureHandler: { _ in },
      sampleHandler: { _ in retiredSubscriberReceivedSample.fulfill() },
      completionHandler: { result in
        if case .success = result { XCTFail("Expected start failure") }
        failedStart.fulfill()
      })

    capture.failStart(FakeAudioCaptureError.expected)
    await fulfillment(of: [failedStart], timeout: 1)
    XCTAssertEqual(capture.stopCount, 1)

    let retriedStart = expectation(description: "retry start")
    let retrySubscriberReceivedSample = expectation(description: "retry subscriber sample")
    _ = coordinator.subscribeAudio(
      deviceID: "device",
      failureHandler: { _ in },
      sampleHandler: { _ in retrySubscriberReceivedSample.fulfill() },
      completionHandler: { result in
        if case .failure(let error) = result { XCTFail("Unexpected retry failure: \(error)") }
        retriedStart.fulfill()
      })
    capture.completeStart()
    await fulfillment(of: [retriedStart], timeout: 1)

    capture.emit(try makeEmptySampleBuffer())
    await fulfillment(of: [retrySubscriberReceivedSample], timeout: 1)
    await fulfillment(of: [retiredSubscriberReceivedSample], timeout: 0.05)
  }

  func testWorkspaceAudioRuntimeFailureRetiresCaptureAndNextSubscriptionRecreatesIt() async {
    let failedCapture = DelayedAudioCaptureService()
    let replacementCapture = DelayedAudioCaptureService()
    let captures = AudioCaptureServiceSequence([failedCapture, replacementCapture])
    let coordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { CameraCaptureService() },
      audioCaptureServiceFactory: { captures.next() })
    let firstStarted = expectation(description: "first capture started")
    let runtimeFailure = expectation(description: "runtime failure delivered")
    _ = coordinator.subscribeAudio(
      deviceID: "device",
      failureHandler: { _ in runtimeFailure.fulfill() },
      sampleHandler: { _ in },
      completionHandler: { _ in firstStarted.fulfill() })
    failedCapture.completeStart()
    await fulfillment(of: [firstStarted], timeout: 1)

    var previousFormat = AudioStreamBasicDescription()
    previousFormat.mSampleRate = 44_100
    var currentFormat = AudioStreamBasicDescription()
    currentFormat.mSampleRate = 48_000
    failedCapture.emitRuntimeFailure(
      .audioFormatChanged(
        deviceID: "device", previous: previousFormat, current: currentFormat))
    await fulfillment(of: [runtimeFailure], timeout: 1)
    XCTAssertEqual(failedCapture.stopCount, 1)

    let replacementStarted = expectation(description: "replacement capture started")
    _ = coordinator.subscribeAudio(
      deviceID: "device", failureHandler: { _ in }, sampleHandler: { _ in },
      completionHandler: { _ in replacementStarted.fulfill() })
    replacementCapture.completeStart()
    await fulfillment(of: [replacementStarted], timeout: 1)
    XCTAssertEqual(replacementCapture.startCount, 1)

    let stopped = expectation(description: "workspace stopped")
    coordinator.stopAndReset { stopped.fulfill() }
    await fulfillment(of: [stopped], timeout: 1)
  }

  func testRuntimeFailedAudioCaptureRetainsUnsubscribeFenceUntilCopiedCallbackFinishes()
    async throws
  {
    let capture = DelayedAudioCaptureService()
    let coordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { CameraCaptureService() },
      audioCaptureServiceFactory: { capture })
    let started = expectation(description: "capture started")
    let handlerEntered = expectation(description: "copied handler entered")
    let unsubscribeCompletion = CallbackSpy()
    let releaseHandler = DispatchSemaphore(value: 0)
    let subscription = coordinator.subscribeAudio(
      deviceID: "device",
      failureHandler: { _ in },
      sampleHandler: { _ in
        handlerEntered.fulfill()
        releaseHandler.wait()
      },
      completionHandler: { _ in started.fulfill() })
    capture.completeStart()
    await fulfillment(of: [started], timeout: 1)

    DispatchQueue.global().async {
      capture.emit(try? makeEmptySampleBuffer())
    }
    await fulfillment(of: [handlerEntered], timeout: 1)

    var previousFormat = AudioStreamBasicDescription()
    previousFormat.mSampleRate = 44_100
    var currentFormat = AudioStreamBasicDescription()
    currentFormat.mSampleRate = 48_000
    capture.emitRuntimeFailure(
      .audioFormatChanged(
        deviceID: "device", previous: previousFormat, current: currentFormat))
    coordinator.unsubscribeAudio(subscription) { unsubscribeCompletion.receive() }
    XCTAssertEqual(unsubscribeCompletion.count, 0)

    releaseHandler.signal()
    let unsubscribeFinished = await waitUntil { unsubscribeCompletion.count == 1 }
    XCTAssertTrue(unsubscribeFinished)
  }

  func testWorkspaceAudioRuntimeFailureDuringStartFailsStartCompletion() async {
    let capture = DelayedAudioCaptureService()
    let coordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { CameraCaptureService() },
      audioCaptureServiceFactory: { capture })
    let runtimeFailureDelivered = expectation(description: "runtime failure delivered")
    let startCompleted = expectation(description: "start completion failed")
    var previousFormat = AudioStreamBasicDescription()
    previousFormat.mSampleRate = 44_100
    var currentFormat = AudioStreamBasicDescription()
    currentFormat.mSampleRate = 48_000
    let failure = CaptureSessionRuntimeFailure.audioFormatChanged(
      deviceID: "device", previous: previousFormat, current: currentFormat)

    _ = coordinator.subscribeAudio(
      deviceID: "device",
      failureHandler: { received in
        XCTAssertEqual(received, failure)
        runtimeFailureDelivered.fulfill()
      },
      sampleHandler: { _ in },
      completionHandler: { result in
        guard case .failure(let error) = result,
          let received = error as? CaptureSessionRuntimeFailure
        else {
          XCTFail("Expected start to fail after the runtime failure")
          startCompleted.fulfill()
          return
        }
        XCTAssertEqual(received, failure)
        startCompleted.fulfill()
      })

    capture.emitRuntimeFailure(failure)
    await fulfillment(of: [runtimeFailureDelivered], timeout: 1)
    capture.completeStart()
    await fulfillment(of: [startCompleted], timeout: 1)
    XCTAssertEqual(capture.stopCount, 1)
  }

  func testWorkspaceShutdownWaitsForRuntimeFailedAudioCaptureToStop() async {
    let capture = DelayedAudioCaptureService()
    capture.completesStopImmediately = false
    let coordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { CameraCaptureService() },
      audioCaptureServiceFactory: { capture })
    let started = expectation(description: "capture started")
    _ = coordinator.subscribeAudio(
      deviceID: "device", failureHandler: { _ in }, sampleHandler: { _ in },
      completionHandler: { _ in started.fulfill() })
    capture.completeStart()
    await fulfillment(of: [started], timeout: 1)

    var previousFormat = AudioStreamBasicDescription()
    previousFormat.mSampleRate = 44_100
    var currentFormat = AudioStreamBasicDescription()
    currentFormat.mSampleRate = 48_000
    capture.emitRuntimeFailure(
      .audioFormatChanged(
        deviceID: "device", previous: previousFormat, current: currentFormat))
    XCTAssertEqual(capture.stopCount, 1)

    let stopped = expectation(description: "workspace stopped after failed capture stops")
    coordinator.stopAndReset { stopped.fulfill() }
    XCTAssertFalse(coordinator.isFullyStopped())

    capture.completeStop()
    await fulfillment(of: [stopped], timeout: 1)
    XCTAssertTrue(coordinator.isFullyStopped())
  }

  func testProgramAudioRestartStopCancelsPendingCompletionExactlyOnce() async {
    let capture = DelayedAudioCaptureService()
    let startRequested = expectation(description: "capture start requested")
    capture.startRequested = { startRequested.fulfill() }
    let controller = ProgramAudioInputCaptureController(makeCaptureService: { capture })
    let channel = ProgramAudioChannel(
      component: .inputAudioDevice(InputAudioDeviceComponent()))
    let channels = [channel]
    let completion = AudioRestartResultSpy()
    let completionDelivered = expectation(description: "restart completion")

    controller.restart(
      audioChannels: channels,
      inputAudioDeviceMappings: [channels.inputAudioDeviceMappingKey(for: channel): "device"],
      failureHandler: { _ in },
      sampleHandler: { _, _, _ in },
      completionHandler: {
        completion.receive($0)
        completionDelivered.fulfill()
      })
    await fulfillment(of: [startRequested], timeout: 1)

    controller.stop()
    await fulfillment(of: [completionDelivered], timeout: 1)
    XCTAssertEqual(completion.count, 1)
    XCTAssertTrue(completion.lastErrorIsCancellation)

    capture.completeStart()
    XCTAssertEqual(completion.count, 1)
  }

  func testProgramAudioRestartSynchronousNestedFailureCompletesExactlyOnce() async {
    let firstCapture = ImmediateAudioCaptureService(result: .success(()))
    let secondCapture = ImmediateAudioCaptureService(
      result: .failure(FakeAudioCaptureError.expected))
    let factory = AudioCaptureServiceSequence([firstCapture, secondCapture])
    let controller = ProgramAudioInputCaptureController(makeCaptureService: { factory.next() })
    let firstChannel = ProgramAudioChannel(
      id: "first",
      component: .inputAudioDevice(InputAudioDeviceComponent()))
    let secondChannel = ProgramAudioChannel(
      id: "second",
      component: .inputAudioDevice(InputAudioDeviceComponent()))
    let channels = [firstChannel, secondChannel]
    let completion = AudioRestartResultSpy()
    let completionDelivered = expectation(description: "restart completion")

    controller.restart(
      audioChannels: channels,
      inputAudioDeviceMappings: [
        channels.inputAudioDeviceMappingKey(for: firstChannel): "first-device",
        channels.inputAudioDeviceMappingKey(for: secondChannel): "second-device",
      ],
      failureHandler: { _ in },
      sampleHandler: { _, _, _ in },
      completionHandler: {
        completion.receive($0)
        completionDelivered.fulfill()
      })

    await fulfillment(of: [completionDelivered], timeout: 1)
    XCTAssertEqual(completion.count, 1)
    XCTAssertFalse(completion.succeeded)
    XCTAssertFalse(completion.lastErrorIsCancellation)
  }

  func testSessionRecordServiceHasNoCaptureStartupAndBecomesTerminal() async throws {
    let baseDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: baseDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let service = try SessionRecordService(
      baseDirectory: baseDirectory,
      recordID: "lifecycle-test",
      writerConfiguration: SegmentedMP4WriterConfiguration(
        width: 16, height: 16, frameRate: 30, videoBitRate: 100_000),
      audioTracks: [
        SessionRecordAudioTrack(
          key: "input", deviceID: "device", trackID: "input",
          displayName: "Input", fileNameStem: "InputDevices/Input")
      ],
      failureHandler: { error in XCTFail("Unexpected record failure: \(error)") })
    let startCompleted = expectation(description: "record start completed")
    service.start { result in
      if case .failure(let error) = result { XCTFail("Unexpected start failure: \(error)") }
      startCompleted.fulfill()
    }
    await fulfillment(of: [startCompleted], timeout: 1)

    let stopCompleted = expectation(description: "record stop completed")
    service.stopPreservingIncompletePackage { result in
      guard case .preservedIncomplete = result else {
        XCTFail("Expected an incomplete package result")
        stopCompleted.fulfill()
        return
      }
      stopCompleted.fulfill()
    }
    await fulfillment(of: [stopCompleted], timeout: 2)

    let repeatedStop = expectation(description: "terminal result returned once to repeat caller")
    service.stop { result in
      guard case .preservedIncomplete = result else {
        XCTFail("Repeated stop must return the stored terminal result")
        repeatedStop.fulfill()
        return
      }
      repeatedStop.fulfill()
    }
    await fulfillment(of: [repeatedStop], timeout: 1)

    let rejected = expectation(description: "record restart rejected")
    service.start { result in
      guard case .failure(let error) = result,
        let serviceError = error as? SessionRecordServiceError,
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

  func testSessionRecordServiceDefersPackageCreationUntilFirstMedia() async throws {
    let baseDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: baseDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let service = try SessionRecordService(
      baseDirectory: baseDirectory,
      recordID: "diagnostics-stop-order-test",
      writerConfiguration: SegmentedMP4WriterConfiguration(
        width: 16, height: 16, frameRate: 30, videoBitRate: 100_000),
      audioTracks: [],
      diagnosticsContext: RecordingDiagnosticsContext(
        launchID: UUID(), launchUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds),
      failureHandler: { error in XCTFail("Unexpected record failure: \(error)") })

    let started = expectation(description: "record started")
    service.start { result in
      if case .failure(let error) = result { XCTFail("Unexpected start failure: \(error)") }
      started.fulfill()
    }
    await fulfillment(of: [started], timeout: 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: service.packageDirectory.path))

    let stopped = expectation(description: "record stopped")
    service.stopPreservingIncompletePackage { _ in stopped.fulfill() }
    await fulfillment(of: [stopped], timeout: 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: service.packageDirectory.path))
  }

  func testSessionRecordServiceRejectsConcurrentDeferredPackageCreation() async throws {
    let baseDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: baseDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let configuration = SegmentedMP4WriterConfiguration(
      width: 16, height: 16, frameRate: 30, videoBitRate: 100_000)
    let first = try SessionRecordService(
      baseDirectory: baseDirectory,
      recordID: "shared-record",
      writerConfiguration: configuration,
      audioTracks: [], failureHandler: { _ in })
    let second = try SessionRecordService(
      baseDirectory: baseDirectory,
      recordID: "shared-record",
      writerConfiguration: configuration,
      audioTracks: [], failureHandler: { _ in })
    first.start { _ in }
    second.start { _ in }

    XCTAssertThrowsError(try first.acceptFirstVideo(makeEmptySampleBuffer()))
    XCTAssertThrowsError(try second.acceptFirstVideo(makeEmptySampleBuffer())) { error in
      guard let serviceError = error as? SessionRecordServiceError,
        case .recordingPackageAlreadyExists = serviceError
      else {
        XCTFail("Expected the deferred package reservation collision, got \(error)")
        return
      }
    }

    await withCheckedContinuation { continuation in
      first.cancelBeforeFirstVideo { _ in continuation.resume() }
    }
    await withCheckedContinuation { continuation in
      second.cancelBeforeFirstVideo { _ in continuation.resume() }
    }
  }

  func testSessionRecordServiceNormalStopWithoutFirstVideoFails() async throws {
    let baseDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: baseDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let service = try SessionRecordService(
      baseDirectory: baseDirectory,
      recordID: "missing-video-stop-test",
      writerConfiguration: SegmentedMP4WriterConfiguration(
        width: 16, height: 16, frameRate: 30, videoBitRate: 100_000),
      audioTracks: [],
      failureHandler: { error in XCTFail("Unexpected record failure: \(error)") })
    let started = expectation(description: "record started")
    service.start { _ in started.fulfill() }
    await fulfillment(of: [started], timeout: 1)

    let stopped = expectation(description: "normal stop reports missing video")
    service.stop { result in
      guard case .failed(let error) = result,
        let flowError = error as? ProgramOutputFlowInterruptionError,
        case .recordingFinalizationFailed = flowError
      else {
        XCTFail("Expected normal stop without video to fail")
        stopped.fulfill()
        return
      }
      stopped.fulfill()
    }
    await fulfillment(of: [stopped], timeout: 1)
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
      sharedH264Service: try ProgramOutputSharedH264Service(slotCount: 2, slotSize: 1_024),
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

private func makeEmptySampleBuffer() throws -> CMSampleBuffer {
  var sampleBuffer: CMSampleBuffer?
  let status = CMSampleBufferCreate(
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
    sampleBufferOut: &sampleBuffer)
  XCTAssertEqual(status, noErr)
  return try XCTUnwrap(sampleBuffer)
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
  private var mainAudioMixHandlers: [UUID: @Sendable (CMSampleBuffer) -> Void] = [:]

  var gainUpdates: [ProgramPreferences] { lock.withLock { storedGainUpdates } }
  var isStartPending: Bool { lock.withLock { startCompletion != nil } }

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

  func addMainAudioMixHandler(
    _ handler: @escaping @Sendable (CMSampleBuffer) -> Void
  ) -> UUID {
    let id = UUID()
    lock.withLock { mainAudioMixHandlers[id] = handler }
    return id
  }
  func removeMainAudioMixHandler(id: UUID) {
    lock.withLock { mainAudioMixHandlers[id] = nil }
  }
  func emitMainAudioMix(_ sampleBuffer: CMSampleBuffer) {
    let handlers = lock.withLock { Array(mainAudioMixHandlers.values) }
    for handler in handlers { handler(sampleBuffer) }
  }
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

private final class AudioRestartResultSpy: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<Void, any Error>] = []
  var count: Int { lock.withLock { results.count } }
  var succeeded: Bool {
    lock.withLock {
      guard let result = results.last else { return false }
      if case .success = result { return true }
      return false
    }
  }
  var lastErrorIsCancellation: Bool {
    lock.withLock {
      guard let result = results.last, case .failure(let error) = result else { return false }
      return error is CancellationError
    }
  }
  func receive(_ result: Result<Void, any Error>) { lock.withLock { results.append(result) } }
}

private final class ImmediateAudioCaptureService: ProgramAudioCaptureStreaming, @unchecked Sendable
{
  let result: Result<Void, any Error>

  init(result: Result<Void, any Error>) { self.result = result }

  func startAudioCapture(
    audioDeviceID: String?,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    handler: @escaping @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    _ = audioDeviceID
    _ = failureHandler
    _ = handler
    completionHandler(result)
  }

  func stop(completionHandler: @escaping @Sendable () -> Void) { completionHandler() }
}

private final class AudioCaptureServiceSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var services: [any ProgramAudioCaptureStreaming]

  init(_ services: [any ProgramAudioCaptureStreaming]) { self.services = services }

  func next() -> any ProgramAudioCaptureStreaming {
    lock.withLock { services.removeFirst() }
  }
}

private final class DelayedAudioCaptureService: ProgramAudioCaptureStreaming, @unchecked Sendable {
  private struct State {
    var completion: (@Sendable (Result<Void, any Error>) -> Void)?
    var failureHandler: (@Sendable (CaptureSessionRuntimeFailure) -> Void)?
    var sampleHandler: (@Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void)?
    var isActive = false
    var stopCount = 0
    var stopCompletion: (@Sendable () -> Void)?
    var startCount = 0
  }

  private let lock = NSLock()
  private var state = State()
  var startRequested: (@Sendable () -> Void)?
  var completesStopImmediately = true
  var isActive: Bool { lock.withLock { state.isActive } }
  var stopCount: Int { lock.withLock { state.stopCount } }
  var startCount: Int { lock.withLock { state.startCount } }

  func startAudioCapture(
    audioDeviceID: String?,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    handler: @escaping @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    _ = audioDeviceID
    lock.withLock {
      state.startCount += 1
      state.completion = completionHandler
      state.failureHandler = failureHandler
      state.sampleHandler = handler
    }
    startRequested?()
  }

  func completeStart() {
    completeStart(with: .success(()))
  }

  func failStart(_ error: any Error) {
    completeStart(with: .failure(error))
  }

  func emitRuntimeFailure(_ failure: CaptureSessionRuntimeFailure) {
    lock.withLock { state.failureHandler }?(failure)
  }

  func emit(_ sampleBuffer: CMSampleBuffer?) {
    guard let sampleBuffer else { return }
    lock.withLock { state.sampleHandler }?(sampleBuffer, .audio)
  }

  private func completeStart(with result: Result<Void, any Error>) {
    let completion = lock.withLock { () -> (@Sendable (Result<Void, any Error>) -> Void)? in
      if case .success = result { state.isActive = true }
      let completion = state.completion
      state.completion = nil
      return completion
    }
    completion?(result)
  }

  func stop(completionHandler: @escaping @Sendable () -> Void) {
    let completesImmediately = lock.withLock { () -> Bool in
      state.stopCount += 1
      state.isActive = false
      if !completesStopImmediately {
        state.stopCompletion = completionHandler
        return false
      }
      return true
    }
    if completesImmediately { completionHandler() }
  }

  func completeStop() {
    let completion = lock.withLock { () -> (@Sendable () -> Void)? in
      let completion = state.stopCompletion
      state.stopCompletion = nil
      return completion
    }
    completion?()
  }
}

private enum FakeAudioCaptureError: Error {
  case expected
}
