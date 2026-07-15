// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXProgram
import LDTXProgramRendering
import XCTest

@testable import LDTXProgramRuntime

@MainActor
final class ProgramOutputSessionTests: XCTestCase {
  func testSessionKeepsInjectedDiagnosticIdentifier() {
    let id = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let session = ProgramOutputSession(
      id: id,
      activeProgramRuntime: ActiveProgramRuntime(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator()
      )
    )

    XCTAssertEqual(session.id, id)
  }

  func testYouTubeOutputRecoveryExhaustionRequiresImmediateGlobalStop() {
    XCTAssertTrue(
      ProgramOutputSessionError.outputServiceRecoveryExhausted("reset limit")
        .requiresImmediateGlobalStop)
    XCTAssertFalse(ProgramOutputSessionError.sessionAlreadyUsed.requiresImmediateGlobalStop)
  }

  func testEncodedVideoFanoutDeliversSameSampleToRecordingAndService() throws {
    let recording = VideoConsumerSpy()
    let service = VideoConsumerSpy()
    let fanout = ProgramEncodedVideoFanout { error in
      XCTFail("Unexpected fanout error: \(error)")
    }
    fanout.recordingPipeline = recording
    fanout.mediaBatcher = service
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

    fanout.receive(.success(sampleBuffer))

    XCTAssertTrue(recording.sampleBuffer === sampleBuffer)
    XCTAssertTrue(service.sampleBuffer === sampleBuffer)
  }

  func testStopWhileStartingCompletesStartExactlyOnce() async {
    let session = ProgramOutputSession(
      activeProgramRuntime: ActiveProgramRuntime(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator()))
    let startCompleted = expectation(description: "start completed")
    let stopCompleted = expectation(description: "stop completed")
    var startCompletionCount = 0
    var startError: Error?

    session.start(
      snapshot: ProgramPreviewSnapshot(
        definition: .fillSolidColor,
        composite: CompositeProgramDefinition(),
        audioChannels: [],
        canvasWidth: 16,
        canvasHeight: 16,
        outputWidth: 16,
        outputHeight: 16,
        frameRate: 30,
        timeSeconds: 0,
        programVideoPTSInputKey: nil,
        programAudioDriverKey: nil,
        cameraIDsByInputKey: [:],
        cameraInputColorOverrides: [:],
        backgroundRemovalInputKeys: []),
      endpoint: nil,
      recordingBaseDirectory: nil,
      programPreferences: ProgramPreferences(),
      audioDeviceIDsByInputKey: [:],
      audioRenderer: ProgramAudioMonitor(),
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
}

private final class VideoConsumerSpy: ProgramEncodedVideoConsumer, @unchecked Sendable {
  private let lock = NSLock()
  private var storedSampleBuffer: CMSampleBuffer?
  var sampleBuffer: CMSampleBuffer? { lock.withLock { storedSampleBuffer } }
  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    lock.withLock { storedSampleBuffer = sampleBuffer }
  }
}
