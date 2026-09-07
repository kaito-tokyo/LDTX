// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import CoreMedia
import Foundation
import LDTXAudioEngine
import Testing

@testable import LDTXProgramRuntime

private final class AudioSamples: @unchecked Sendable {
  private let lock = NSLock()
  private var samples: [CMSampleBuffer] = []
  func append(_ sample: CMSampleBuffer) { lock.withLock { samples.append(sample) } }
  var values: [CMSampleBuffer] { lock.withLock { samples } }
}

@Suite struct ProgramAudioMonitorMixerTests {
  @Test func noInputStillEmitsClockedSilenceAfterDeadline() throws {
    let engine = WorkspaceAudioEngine(hardwareEnabled: false)
    let bus = engine.configureBus(owner: UUID(), routes: [], master: 1)
    let samples = AudioSamples()
    let subscription = engine.subscribe(source: bus, raw: false, handler: samples.append)
    defer { subscription.cancel() }
    LDTXAudioAdvance(engine.native, 1_000_000_000)
    LDTXAudioAdvance(engine.native, 1_199_999_999)
    #expect(samples.values.isEmpty)
    LDTXAudioAdvance(engine.native, 1_200_000_000)
    let first = try #require(samples.values.first)
    #expect(first.numSamples == 1024)
    #expect(first.presentationTimeStamp == CMTime(value: 1, timescale: 1))
    let data = try #require(first.dataBuffer)
    var pcm = [Float](repeating: 1, count: 2048)
    #expect(
      CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: 8192, destination: &pcm) == noErr)
    #expect(pcm.allSatisfy { $0 == 0 })
  }

  @Test func catchUpIsBoundedAndUnsubscribeFencesDelivery() {
    let engine = WorkspaceAudioEngine(hardwareEnabled: false)
    let bus = engine.configureBus(owner: UUID(), routes: [], master: 1)
    let samples = AudioSamples()
    let subscription = engine.subscribe(source: bus, raw: false, handler: samples.append)
    LDTXAudioAdvance(engine.native, 1_000_000_000)
    LDTXAudioAdvance(engine.native, 2_000_000_000)
    #expect(samples.values.count == 8)
    for pair in zip(samples.values, samples.values.dropFirst()) {
      #expect(pair.0.presentationTimeStamp < pair.1.presentationTimeStamp)
    }
    subscription.cancel()
    LDTXAudioAdvance(engine.native, 3_000_000_000)
    #expect(samples.values.count == 8)
  }

  @Test func stopIsIdempotentAndWaitsForNotifications() async {
    let engine = WorkspaceAudioEngine(hardwareEnabled: false)
    let bus = engine.configureBus(owner: UUID(), routes: [], master: 1)
    let samples = AudioSamples()
    let subscription = engine.subscribe(source: bus, raw: false, handler: samples.append)
    LDTXAudioAdvance(engine.native, 1_000_000_000)
    LDTXAudioAdvance(engine.native, 1_200_000_000)
    await withCheckedContinuation { continuation in engine.stop { continuation.resume() } }
    await withCheckedContinuation { continuation in engine.stop { continuation.resume() } }
    LDTXAudioAdvance(engine.native, 2_000_000_000)
    #expect(samples.values.count == 1)
    subscription.cancel()
  }
  @Test func concurrentCancellationBothWaitForActiveNotification() {
    let engine = WorkspaceAudioEngine(hardwareEnabled: false)
    let bus = engine.configureBus(owner: UUID(), routes: [], master: 1)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let returned = DispatchSemaphore(value: 0)
    let started = DispatchGroup()
    let finished = DispatchGroup()
    let rendered = DispatchGroup()
    let subscription = engine.subscribe(source: bus, raw: false) { _ in
      entered.signal()
      release.wait()
    }
    LDTXAudioAdvance(engine.native, 1_000_000_000)
    rendered.enter()
    DispatchQueue.global().async {
      LDTXAudioAdvance(engine.native, 1_200_000_000)
      rendered.leave()
    }
    guard entered.wait(timeout: .now() + 5) == .success else {
      release.signal()
      Issue.record("Notification did not start")
      return
    }
    for _ in 0..<2 {
      started.enter()
      finished.enter()
      DispatchQueue.global().async {
        started.leave()
        subscription.cancel()
        returned.signal()
        finished.leave()
      }
    }
    #expect(started.wait(timeout: .now() + 5) == .success)
    #expect(returned.wait(timeout: .now() + 0.2) == .timedOut)
    release.signal()
    #expect(finished.wait(timeout: .now() + 5) == .success)
    #expect(rendered.wait(timeout: .now() + 5) == .success)
    LDTXAudioAdvance(engine.native, 1_400_000_000)
    #expect(entered.wait(timeout: .now()) == .timedOut)
  }

}
