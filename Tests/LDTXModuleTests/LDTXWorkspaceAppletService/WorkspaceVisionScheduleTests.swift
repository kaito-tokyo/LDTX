// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceBundleFormat
import Testing

@Suite("Vision schedule planning", .tags(.easy))
struct WorkspaceVisionScheduleUnitTestSuite {
  @Test("LUB-1029: Output retains membership but allows ordering and mix changes")
  func outputRetainsMembershipButAllowsOrderingAndMixChanges() {
    var live = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    live.landscapeProgramPreferences[1, default: .init()].videoLayerInternalIds = [3, 5, 5]
    let baseline = live
    live.landscapeProgramPreferences[1, default: .init()].videoLayerInternalIds = [5, 3, 5]
    #expect(
      WorkspaceV4PersistenceCoordinator.preferencesDuringOutput(live, membership: baseline) == live)
    live.landscapeProgramPreferences[1, default: .init()].videoLayerInternalIds = [3, 7]
    live.landscapeProgramPreferences[1, default: .init()].audioMasterVolumeDecibels.set(
      num: -100, den: 10)
    live.landscapeProgramPreferences[1, default: .init()].videoLayerHidden[3] = true
    let safe = WorkspaceV4PersistenceCoordinator.preferencesDuringOutput(live, membership: baseline)
    #expect(safe.landscapeProgramPreferences[1]?.videoLayerInternalIds == [3, 5, 5])
    #expect(safe.landscapeProgramPreferences[1]?.audioMasterVolumeDecibels.num == -100)
    #expect(safe.landscapeProgramPreferences[1]?.videoLayerHidden[3] == true)
  }

  @MainActor
  @Test("LUB-1029: Structural reload is deferred until output is idle")
  func structuralReloadIsDeferredUntilOutputIsIdle() throws {
    var live = WorkspaceV4Bundle(definition: .init(), preferences: .init())
    live.preferences.landscapeProgramPreferences[1, default: .init()].videoLayerInternalIds = [
      3, 5,
    ]
    let coordinator = WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: { live }, replaceWorkspace: { live = $0 })
    try coordinator.adoptRuntimeWorkspace(live)
    coordinator.setOutputActive(true)
    live.preferences.landscapeProgramPreferences[1, default: .init()].videoLayerInternalIds = [
      3, 7,
    ]
    #expect(
      coordinator.runtimeWorkspace.preferences.landscapeProgramPreferences[1]?.videoLayerInternalIds
        == [3, 5])
    coordinator.setOutputActive(false)
    #expect(
      coordinator.runtimeWorkspace.preferences.landscapeProgramPreferences[1]?.videoLayerInternalIds
        == [3, 7])
  }
  @Test("LUB-1029: Distributes phases and places without overlap")
  func distributesPhasesAndPlacesWithoutOverlap() {
    var values = [0, 500_000]
    var schedule = WorkspaceVisionSchedule(
      triggers: [
        .init(visionID: 1, periodMilliseconds: 5000), .init(visionID: 2, periodMilliseconds: 5000),
      ],
      random: { _ in values.removeFirst() })
    let plan = schedule.plan(startMilliseconds: 0, random: { $0 - 1 })
    #expect(plan.dropped == 0)
    #expect(plan.entries.prefix(2).map(\.offsetMilliseconds) == [0, 2500])
    #expect(plan.entries.count == 12)
    #expect(
      zip(plan.entries, plan.entries.dropFirst()).allSatisfy {
        $1.offsetMilliseconds - $0.offsetMilliseconds >= 3
      })
  }

  @Test("LUB-1029: Carries fractional and long periods across frames")
  func carriesFractionalAndLongPeriodsAcrossFrames() {
    var schedule = WorkspaceVisionSchedule(
      triggers: [.init(visionID: 1, periodMilliseconds: 70000.25)], random: { _ in 500_000 })
    #expect(schedule.plan(startMilliseconds: 0, random: { _ in 0 }).entries.isEmpty)
    #expect(
      schedule.plan(startMilliseconds: 30000, random: { _ in 0 }).entries.first?.offsetMilliseconds
        == 5000)
    #expect(schedule.plan(startMilliseconds: 60000, random: { _ in 0 }).entries.isEmpty)
    #expect(
      schedule.plan(startMilliseconds: 90000, random: { _ in 0 }).entries.first?.offsetMilliseconds
        == 15000)
  }

  @Test("LUB-1029: Multiple triggers for one vision remain separate")
  func multipleTriggersForOneVisionRemainSeparate() {
    var schedule = WorkspaceVisionSchedule(
      triggers: [
        .init(visionID: 1, periodMilliseconds: 15000),
        .init(visionID: 1, periodMilliseconds: 15000),
      ],
      random: { _ in 0 })
    let plan = schedule.plan(startMilliseconds: 0, random: { $0 - 1 })
    #expect(plan.entries.map(\.offsetMilliseconds) == [0, 3, 15000, 15003])
  }

  @Test("LUB-1029: Dense input uses bounded sampling") func denseInputUsesBoundedSampling() {
    var generator = SeededGenerator(seed: 7)
    func random(_ limit: Int) -> Int { Int.random(in: 0..<limit, using: &generator) }
    var schedule = WorkspaceVisionSchedule(
      triggers: (1...100).map { .init(visionID: Int64($0), periodMilliseconds: 0.1) },
      random: random)
    let plan = schedule.plan(startMilliseconds: 0, random: random)
    #expect(plan.entries.count <= 10000)
    #expect(plan.dropped > 2_900_000)
    #expect(Set(plan.entries.map(\.visionID)).count > 1)
    #expect(plan.entries.last!.offsetMilliseconds + 3 <= 30000)
  }

  @Test("LUB-1029: Ignores invalid periods and skips missed frames")
  func ignoresInvalidPeriodsAndSkipsMissedFrames() {
    var schedule = WorkspaceVisionSchedule(
      triggers: [Double.nan, .infinity, -1, 0, 7000].map {
        .init(visionID: 1, periodMilliseconds: $0)
      },
      random: { _ in 0 })
    #expect(schedule.streams.count == 1)
    _ = schedule.plan(startMilliseconds: 0, random: { _ in 0 })
    let plan = schedule.plan(startMilliseconds: 90000, random: { $0 - 1 })
    #expect(plan.entries.first?.offsetMilliseconds == 1000)
  }

  @Test("LUB-1029: Late collisions are randomly rejected and retried")
  func lateCollisionsAreRandomlyRejectedAndRetried() {
    var schedule = WorkspaceVisionSchedule(
      triggers: (1...10).map { .init(visionID: Int64($0), periodMilliseconds: 30000) },
      random: { _ in 999_999 })
    let plan = schedule.plan(startMilliseconds: 0, random: { $0 - 1 })
    #expect(plan.entries.isEmpty)
    #expect(plan.dropped == 10)
  }
}

private struct SeededGenerator: RandomNumberGenerator {
  var seed: UInt64
  mutating func next() -> UInt64 {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return seed
  }
}

@MainActor
@Suite("Vision schedule execution", .tags(.easy))
struct WorkspaceVisionSchedulerUnitTestSuite {
  @Test("LUB-1029: Skips unprepared and overdue requests without catch up")
  func skipsUnpreparedAndOverdueRequestsWithoutCatchUp() async {
    var time = 0.0
    var ready = false
    var calls = 0
    let scheduler = WorkspaceVisionScheduler(
      now: { time }, random: { _ in 0 }, automaticTimer: false)
    _ = scheduler.synchronize(
      triggers: [.init(visionID: 1, periodMilliseconds: 10)], isReady: { _ in ready },
      execute: { _, _ in calls += 1 })
    scheduler.tick()
    #expect(scheduler.skipped == 1)
    ready = true
    time = 15
    scheduler.tick()
    #expect(scheduler.skipped == 2)
    #expect(calls == 0)
    time = 20
    scheduler.tick()
    for _ in 0..<10 { await Task.yield() }
    #expect(calls == 1)
    await scheduler.stop()
  }
  @Test("LUB-1029: Skips busy occurrences and waits on stop")
  func skipsBusyOccurrencesAndWaitsOnStop() async {
    var time = 0.0
    var calls = 0
    var resume: CheckedContinuation<Void, Never>?
    let scheduler = WorkspaceVisionScheduler(
      now: { time }, random: { _ in 0 }, automaticTimer: false)
    let generation = scheduler.synchronize(triggers: [.init(visionID: 1, periodMilliseconds: 10)]) {
      _, _ in
      calls += 1
      await withCheckedContinuation { resume = $0 }
    }
    scheduler.tick()
    while resume == nil { await Task.yield() }
    time = 20
    scheduler.tick()
    #expect(calls == 1)
    #expect(scheduler.skipped == 2)
    var didStop = false
    let stop = Task {
      await scheduler.stop()
      didStop = true
    }
    await Task.yield()
    #expect(!scheduler.isCurrent(generation))
    #expect(!didStop)
    resume?.resume()
    await stop.value
    #expect(didStop)
    #expect(scheduler.overruns == 1)
    time = 30
    scheduler.tick()
    #expect(calls == 1)
  }

  @Test("LUB-1029: Synchronization invalidates old generation without cancelling work")
  func synchronizationInvalidatesOldGenerationWithoutCancellingWork() async {
    var time = 0.0
    var resume: CheckedContinuation<Void, Never>?
    var cancelled = false
    let scheduler = WorkspaceVisionScheduler(
      now: { time }, random: { _ in 0 }, automaticTimer: false)
    let old = scheduler.synchronize(triggers: [.init(visionID: 1, periodMilliseconds: 10)]) {
      _, _ in
      await withCheckedContinuation { resume = $0 }
      cancelled = Task.isCancelled
    }
    scheduler.tick()
    while resume == nil { await Task.yield() }
    var ids: [Int64] = []
    let new = scheduler.synchronize(triggers: [.init(visionID: 2, periodMilliseconds: 10)]) {
      id, _ in ids.append(id)
    }
    scheduler.tick()
    #expect(!scheduler.isCurrent(old))
    #expect(scheduler.isCurrent(new))
    #expect(ids.isEmpty)
    resume?.resume()
    for _ in 0..<10 { await Task.yield() }
    time = 10
    scheduler.tick()
    for _ in 0..<10 { await Task.yield() }
    #expect(ids == [2])
    #expect(!cancelled)
    await scheduler.stop()
  }
}
