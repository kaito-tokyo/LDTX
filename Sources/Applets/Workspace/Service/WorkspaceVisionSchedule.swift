// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import OSLog

/// Pure, bounded-memory planning. Times are milliseconds from a monotonic origin.
struct WorkspaceVisionSchedule {
  static let frameMilliseconds = 30_000
  static let budgetMilliseconds = 3

  struct Trigger: Equatable {
    let visionID: Int64
    let periodMilliseconds: Double
  }
  struct Stream {
    let trigger: Trigger
    var next: Double
  }
  struct Entry: Equatable {
    let visionID: Int64
    let offsetMilliseconds: Int
  }
  struct Plan {
    let entries: [Entry]
    let dropped: Int
  }
  private(set) var streams: [Stream]

  init(triggers: [Trigger], random: (Int) -> Int) {
    streams = triggers.filter {
      $0.periodMilliseconds.isFinite && $0.periodMilliseconds > 0
    }.map {
      let period = max(1, $0.periodMilliseconds)
      let trigger = Trigger(visionID: $0.visionID, periodMilliseconds: period)
      return Stream(trigger: trigger, next: Double(random(1_000_000)) / 1_000_000 * period)
    }
  }

  mutating func plan(startMilliseconds: Double, random: (Int) -> Int) -> Plan {
    let end = startMilliseconds + Double(Self.frameMilliseconds)
    var ranges: [(id: Int64, first: Double, period: Double, count: Int, upper: Int)] = []
    var total = 0
    for index in streams.indices {
      let period = streams[index].trigger.periodMilliseconds
      var first = streams[index].next
      if first < startMilliseconds {
        first += ceil((startMilliseconds - first) / period) * period
      }
      let count = first < end ? Int(ceil((end - first) / period)) : 0
      total += count
      ranges.append((streams[index].trigger.visionID, first, period, count, total))
      streams[index].next = first + Double(count) * period
    }
    // Floyd's uniform sampling selects at most 10,000 occurrences without expanding streams.
    let capacity = Self.frameMilliseconds / Self.budgetMilliseconds
    let retained = min(total, capacity)
    var ranks = Set<Int>()
    if retained > 0 {
      for upper in (total - retained)..<total {
        let value = random(upper + 1)
        ranks.insert(ranks.contains(value) ? upper : value)
      }
    }
    let candidates: [(id: Int64, offset: Int, rank: Int)] = ranks.map { rank in
      var low = 0
      var high = ranges.count
      while low < high {
        let middle = (low + high) / 2
        if ranges[middle].upper <= rank { low = middle + 1 } else { high = middle }
      }
      let range = ranges[low]
      let occurrence = rank - (range.upper - range.count)
      let offset = Int(
        (range.first + Double(occurrence) * range.period - startMilliseconds).rounded())
      return (range.id, max(0, offset), rank)
    }.sorted { ($0.offset, $0.rank) < ($1.offset, $1.rank) }
    guard !candidates.isEmpty else { return Plan(entries: [], dropped: total) }
    // Greedy placement fits iff every offset + remaining budgets fits in the frame.
    // Maintain that bound while randomly removing occurrences, rather than rebuilding
    // a 10,000-entry array after each rejection (quadratic on dense inputs).
    var bounds = PlacementBounds(offsets: candidates.map(\.offset), budget: Self.budgetMilliseconds)
    while bounds.maximum > Self.frameMilliseconds {
      bounds.remove(rank: random(bounds.count), budget: Self.budgetMilliseconds)
    }
    var cursor = 0
    let entries = bounds.indices().map { index in
      cursor = max(cursor, candidates[index].offset)
      let entry = Entry(visionID: candidates[index].id, offsetMilliseconds: cursor)
      cursor += Self.budgetMilliseconds
      return entry
    }
    return Plan(entries: entries, dropped: total - entries.count)
  }
}

/// Segment tree supporting uniform removal and prefix budget adjustments in O(log n).
private struct PlacementBounds {
  private var maxima: [Int]
  private var additions: [Int]
  private var counts: [Int]
  private let size: Int
  var maximum: Int { maxima[1] }
  var count: Int { counts[1] }

  init(offsets: [Int], budget: Int) {
    size = offsets.count
    maxima = Array(repeating: 0, count: size * 4)
    additions = maxima
    counts = maxima
    build(1, 0, size, offsets, budget)
  }

  private mutating func build(_ node: Int, _ low: Int, _ high: Int, _ offsets: [Int], _ budget: Int)
  {
    counts[node] = high - low
    if high - low == 1 {
      maxima[node] = offsets[low] + budget * (size - low)
      return
    }
    let middle = (low + high) / 2
    build(node * 2, low, middle, offsets, budget)
    build(node * 2 + 1, middle, high, offsets, budget)
    pull(node)
  }

  private mutating func pull(_ node: Int) {
    maxima[node] = max(maxima[node * 2], maxima[node * 2 + 1]) + additions[node]
    counts[node] = counts[node * 2] + counts[node * 2 + 1]
  }

  mutating func remove(rank: Int, budget: Int) {
    let index = remove(1, 0, size, rank)
    subtractPrefix(1, 0, size, index, budget)
  }

  private mutating func remove(_ node: Int, _ low: Int, _ high: Int, _ rank: Int) -> Int {
    if high - low == 1 {
      counts[node] = 0
      maxima[node] = Int.min / 4
      return low
    }
    let middle = (low + high) / 2
    let index: Int
    if rank < counts[node * 2] {
      index = remove(node * 2, low, middle, rank)
    } else {
      index = remove(node * 2 + 1, middle, high, rank - counts[node * 2])
    }
    pull(node)
    return index
  }

  private mutating func subtractPrefix(
    _ node: Int, _ low: Int, _ high: Int, _ end: Int, _ budget: Int
  ) {
    guard low < end else { return }
    if high <= end {
      additions[node] -= budget
      maxima[node] -= budget
      return
    }
    let middle = (low + high) / 2
    subtractPrefix(node * 2, low, middle, end, budget)
    subtractPrefix(node * 2 + 1, middle, high, end, budget)
    pull(node)
  }

  func indices() -> [Int] {
    var result: [Int] = []
    func collect(_ node: Int, _ low: Int, _ high: Int) {
      guard counts[node] > 0 else { return }
      if high - low == 1 {
        result.append(low)
        return
      }
      let middle = (low + high) / 2
      collect(node * 2, low, middle)
      collect(node * 2 + 1, middle, high)
    }
    collect(1, 0, size)
    return result
  }
}

/// A single automatic execution lane. Work already started is never cancelled.
@MainActor
final class WorkspaceVisionScheduler {
  private let now: () -> Double
  private let random: (Int) -> Int
  private let automaticTimer: Bool
  private var timer: DispatchSourceTimer?
  private var schedule: WorkspaceVisionSchedule?
  private var frameStart = 0.0
  private var entries: [WorkspaceVisionSchedule.Entry] = []
  private var index = 0
  private var origin = 0.0
  private var generation = UUID()
  private var work: Task<Void, Never>?
  private var execute: ((Int64, UUID) async -> Void)?
  private var isReady: (Int64) -> Bool = { _ in true }
  private(set) var dropped = 0
  private(set) var skipped = 0
  private(set) var overruns = 0
  private static let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "VisionScheduler")

  init(
    now: @escaping () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 },
    random: @escaping (Int) -> Int = { Int.random(in: 0..<$0) }, automaticTimer: Bool = true
  ) {
    self.now = now
    self.random = random
    self.automaticTimer = automaticTimer
  }

  isolated deinit { timer?.cancel() }

  func synchronize(
    triggers: [WorkspaceVisionSchedule.Trigger],
    isReady: @escaping (Int64) -> Bool = { _ in true },
    execute: @escaping (Int64, UUID) async -> Void
  ) -> UUID {
    timer?.cancel()
    timer = nil
    generation = UUID()
    self.execute = execute
    self.isReady = isReady
    schedule = WorkspaceVisionSchedule(triggers: triggers, random: random)
    origin = now()
    frameStart = 0
    dropped = 0
    skipped = 0
    overruns = 0
    makePlan()
    if automaticTimer, !triggers.isEmpty {
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.setEventHandler { [weak self] in self?.tick() }
      self.timer = timer
      armTimer()
      timer.resume()
    }
    return generation
  }

  func isCurrent(_ generation: UUID) -> Bool { schedule != nil && self.generation == generation }

  func stop() async {
    timer?.cancel()
    timer = nil
    schedule = nil
    execute = nil
    isReady = { _ in false }
    generation = UUID()
    await work?.value
  }

  func tick() {
    guard schedule != nil else { return }
    let elapsed = now() - origin
    if elapsed >= frameStart + Double(WorkspaceVisionSchedule.frameMilliseconds) {
      skipped += entries.count - index
      frameStart =
        floor(elapsed / Double(WorkspaceVisionSchedule.frameMilliseconds))
        * Double(WorkspaceVisionSchedule.frameMilliseconds)
      makePlan()
    }
    while index < entries.count,
      frameStart + Double(entries[index].offsetMilliseconds) <= elapsed
    {
      let entry = entries[index]
      index += 1
      if work != nil || !isReady(entry.visionID)
        || elapsed - frameStart - Double(entry.offsetMilliseconds)
          >= Double(WorkspaceVisionSchedule.budgetMilliseconds)
      {
        skipped += 1
        continue
      }
      let generation = generation
      let started = now()
      guard let execute else { break }
      work = Task { [weak self] in
        await execute(entry.visionID, generation)
        guard let self else { return }
        if now() - started > Double(WorkspaceVisionSchedule.budgetMilliseconds) { overruns += 1 }
        work = nil
      }
    }
    armTimer()
  }

  private func makePlan() {
    guard let plan = schedule?.plan(startMilliseconds: frameStart, random: random) else { return }
    Self.logger.info(
      "vision-schedule frame=\(self.frameStart) retained=\(plan.entries.count) dropped=\(plan.dropped) skipped=\(self.skipped) overruns=\(self.overruns)"
    )
    entries = plan.entries
    dropped += plan.dropped
    index = 0
  }

  private func armTimer() {
    let next =
      index < entries.count
      ? Double(entries[index].offsetMilliseconds)
      : Double(WorkspaceVisionSchedule.frameMilliseconds)
    let delay = max(0, frameStart + next - (now() - origin))
    timer?.schedule(deadline: .now() + delay / 1000, leeway: .microseconds(100))
  }
}
