// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXProtos
@testable import LDTXWorkspaceAppletService
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ManualOCRIntegrationTestSuite {
  enum Completion: CaseIterable {
    case success, failure, deleted, deletedFromEditor, closed, stopped, changedPackage, paused
  }

  @Test func unavailableFrameCanBeRetried() async {
    let vision = Ldtx_Workspace_V4_OcrVision.with { $0.internalID = 11 }
    var unavailable = true
    var failures = 0
    var results = 0
    let feature = WorkspaceV4VisionFeature(
      scheduler: WorkspaceVisionScheduler(now: { 0 }, random: { _ in 0 }, automaticTimer: false),
      recognizeText: { _, _ in "recovered" })
    let context = WorkspaceV4VisionFeatureContext(
      vision: { $0 == 11 ? vision : nil },
      frameForVision: { _ in
        if unavailable { throw WorkspaceVisionFeatureError.frameUnavailable }
        return .init(image: CIImage(color: .white))
      },
      reportResult: { _, _ in results += 1 },
      reportFailure: { _, _ in failures += 1 })
    feature.synchronize(visions: [.with { $0.ocrVision = vision }], context: context)
    feature.runOCR(visionInternalID: 11)
    while !feature.canRunOCR(visionInternalID: 11) { await Task.yield() }
    #expect(failures == 1)
    #expect(results == 0)
    unavailable = false
    feature.runOCR(visionInternalID: 11)
    while !feature.canRunOCR(visionInternalID: 11) { await Task.yield() }
    #expect(results == 1)
    #expect(feature.resultsByVisionInternalID[11] == "recovered")
    await feature.stop()
  }

  @Test func recognitionBackendFailureIsReportedAndCanBeRetried() async {
    let vision = Ldtx_Workspace_V4_OcrVision.with { $0.internalID = 11 }
    let backendFailure = NSError(
      domain: "ManualOCRTestBackend", code: 11,
      userInfo: [NSLocalizedDescriptionKey: "No available recognition backend."])
    var failing = true
    var results: [String] = []
    var failures: [NSError] = []
    var archives = 0
    let feature = WorkspaceV4VisionFeature(
      scheduler: WorkspaceVisionScheduler(now: { 0 }, random: { _ in 0 }, automaticTimer: false),
      recognizeText: { _, _ in
        if failing { throw backendFailure }
        return "recovered recognition"
      })
    var context = WorkspaceV4VisionFeatureContext(
      vision: { $0 == 11 ? vision : nil },
      frameForVision: { _ in .init(image: CIImage(color: .white)) },
      reportResult: { _, text in results.append(text) },
      reportFailure: { _, error in failures.append(error as NSError) },
      archiveResult: { _, _, _ in archives += 1 })
    context.recordingPackageURL = { URL(fileURLWithPath: "/tmp/backend-failure.ldtxrecord") }
    feature.synchronize(visions: [.with { $0.ocrVision = vision }], context: context)
    feature.runOCR(visionInternalID: 11)
    while !feature.canRunOCR(visionInternalID: 11) { await Task.yield() }
    #expect(failures.count == 1)
    #expect(failures.first === backendFailure)
    #expect(results.isEmpty)
    #expect(feature.resultsByVisionInternalID[11] == nil)
    #expect(archives == 0)
    failing = false
    feature.runOCR(visionInternalID: 11)
    while !feature.canRunOCR(visionInternalID: 11) { await Task.yield() }
    #expect(results == ["recovered recognition"])
    #expect(archives == 1)
    #expect(failures.count == 1)
    await feature.stop()
  }

  @Test(arguments: [false, true], Completion.allCases)
  func manualAdmissionAndCompletion(recording: Bool, completion: Completion) async {
    var vision: Ldtx_Workspace_V4_OcrVision? = .with { $0.internalID = 11 }
    let wrapper = Ldtx_Workspace_V4_VisionWrapper.with { $0.ocrVision = vision! }
    var current = true
    var targetExists = true
    var package = recording ? URL(fileURLWithPath: "/tmp/manual-ocr.ldtxrecord") : nil
    var release: CheckedContinuation<Void, Never>?
    var calls = 0
    var results: [String] = []
    var failures = 0
    var archives = 0
    var timeline: UInt64 = 123
    var archivedTimelines: [UInt64?] = []
    let feature = WorkspaceV4VisionFeature(
      scheduler: WorkspaceVisionScheduler(now: { 0 }, random: { _ in 0 }, automaticTimer: false),
      recognizeText: { _, _ in
        calls += 1
        await withCheckedContinuation { release = $0 }
        if completion == .failure { throw CocoaError(.fileReadUnknown) }
        return "manual result"
      })
    var context = WorkspaceV4VisionFeatureContext(
      vision: { $0 == 11 ? vision : nil },
      frameForVision: { _ in .init(image: CIImage(color: .white)) },
      reportResult: { _, value in results.append(value) },
      reportFailure: { _, _ in failures += 1 },
      archiveResult: { _, _, _ in archives += 1 })
    context.isCurrent = { current }
    context.recordingPackageURL = { package }
    context.recordingTimelineMilliseconds = { timeline }
    context.archiveTimedResult = { _, _, _, captured in
      archives += 1
      archivedTimelines.append(captured)
    }
    feature.synchronize(visions: [wrapper], context: context)
    #expect(feature.canRunOCR(visionInternalID: 11))
    #expect(!feature.canRunOCR(visionInternalID: 99))
    feature.runOCR(visionInternalID: 99)
    feature.runOCR(visionInternalID: 11, isCurrent: { targetExists })
    #expect(!feature.canRunOCR(visionInternalID: 11))
    feature.runOCR(visionInternalID: 11)
    while release == nil { await Task.yield() }
    #expect(calls == 1)
    timeline = 987
    switch completion {
    case .deleted: vision = nil
    case .deletedFromEditor: targetExists = false
    case .closed: current = false
    case .paused: package = nil
    case .changedPackage: package = URL(fileURLWithPath: "/tmp/next.ldtxrecord")
    default: break
    }
    var stopStarted = false
    var drained = false
    let stop: Task<Void, Never>? =
      completion == .stopped
      ? Task {
        stopStarted = true
        await feature.stop()
        drained = true
      } : nil
    if stop != nil {
      while !stopStarted { await Task.yield() }
      #expect(!drained)
    }
    release?.resume()
    if let stop {
      await stop.value
    } else {
      while !feature.canRunOCR(visionInternalID: 11) { await Task.yield() }
      await feature.stop()
    }
    let publishes = completion == .success || completion == .changedPackage || completion == .paused
    #expect(results == (publishes ? ["manual result"] : []))
    #expect(failures == (completion == .failure ? 1 : 0))
    #expect(archives == (recording && completion == .success ? 1 : 0))
    #expect(archivedTimelines.allSatisfy { $0 == 123 })
    #expect(!feature.canRunOCR(visionInternalID: 11))
    feature.runOCR(visionInternalID: 11)
    #expect(calls == 1)
  }
}
