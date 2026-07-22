// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import LDTXRecording

enum PreviewCompositionLoadMapError: Error, LocalizedError {
  case capacityExceeded

  var errorDescription: String? {
    switch self {
    case .capacityExceeded:
      "The system is handling too many preview requests. Try this file again."
    }
  }
}

@MainActor
final class PreviewCompositionLoadMap {
  typealias RequestID = UUID
  private typealias Waiter = @MainActor (Result<AVMutableComposition, Error>) -> Void

  private enum State {
    case empty
    case loading
    case ready(AVMutableComposition)
  }

  private final class Slot {
    var generation: UInt64 = 0
    var url: URL?
    var key: URL?
    var state: State = .empty
    var loadTask: Task<Void, Never>?
    var waiters: [RequestID: Waiter] = [:]
    var lastAccess: UInt64 = 0
    var isAccessingSecurityScopedResource = false
  }

  private let slots: [Slot]
  private var accessOrdinal: UInt64 = 0

  init(maximumCount: Int) {
    precondition(maximumCount > 0)
    slots = (0..<maximumCount).map { _ in Slot() }
  }

  @discardableResult
  func requestComposition(
    for url: URL,
    completion: @escaping @MainActor (Result<AVMutableComposition, Error>) -> Void
  ) -> RequestID {
    let requestID = RequestID()
    let key = url.standardizedFileURL
    accessOrdinal &+= 1

    if let slot = slots.first(where: { $0.key == key }) {
      let slotIndex = slots.firstIndex(where: { $0 === slot }) ?? -1
      slot.lastAccess = accessOrdinal
      switch slot.state {
      case .ready(let composition):
        quickLookPreviewLogger.notice(
          "Load map ready hit in slot \(slotIndex) for \(url.lastPathComponent, privacy: .public), request \(requestID.uuidString, privacy: .public)."
        )
        Task { @MainActor in completion(.success(composition)) }
      case .loading:
        quickLookPreviewLogger.notice(
          "Load map joined slot \(slotIndex) for \(url.lastPathComponent, privacy: .public), request \(requestID.uuidString, privacy: .public)."
        )
        slot.waiters[requestID] = completion
      case .empty:
        break
      }
      return requestID
    }

    guard let slot = reusableSlot() else {
      quickLookPreviewLogger.error(
        "Load map capacity exceeded for \(url.lastPathComponent, privacy: .public), request \(requestID.uuidString, privacy: .public)."
      )
      Task { @MainActor in completion(.failure(PreviewCompositionLoadMapError.capacityExceeded)) }
      return requestID
    }

    reset(slot)
    let slotIndex = slots.firstIndex(where: { $0 === slot }) ?? -1
    slot.generation &+= 1
    let generation = slot.generation
    slot.url = url
    slot.key = key
    slot.state = .loading
    slot.waiters[requestID] = completion
    slot.lastAccess = accessOrdinal
    slot.isAccessingSecurityScopedResource = url.startAccessingSecurityScopedResource()
    quickLookPreviewLogger.notice(
      "Load map started slot \(slotIndex) for \(url.lastPathComponent, privacy: .public), generation \(generation), request \(requestID.uuidString, privacy: .public)."
    )
    slot.loadTask = Task { @MainActor [weak self, weak slot] in
      guard let self, let slot else { return }
      do {
        let package = try RecordingPackage(contentsOf: url)
        let composition = try await RecordingCompositionLoader().load(package: package)
        finishLoading(slot, generation: generation, result: .success(composition))
      } catch {
        finishLoading(slot, generation: generation, result: .failure(error))
      }
    }
    return requestID
  }

  func cancelRequest(_ requestID: RequestID) {
    for (slotIndex, slot) in slots.enumerated()
    where slot.waiters.removeValue(forKey: requestID) != nil {
      quickLookPreviewLogger.notice(
        "Load map removed waiter \(requestID.uuidString, privacy: .public) from slot \(slotIndex); underlying load continues."
      )
    }
  }

  private func reusableSlot() -> Slot? {
    if let emptySlot = slots.first(where: {
      if case .empty = $0.state { true } else { false }
    }) {
      return emptySlot
    }
    return
      slots
      .filter {
        if case .ready = $0.state { true } else { false }
      }
      .min(by: { $0.lastAccess < $1.lastAccess })
  }

  private func finishLoading(
    _ slot: Slot,
    generation: UInt64,
    result: Result<AVMutableComposition, Error>
  ) {
    guard slot.generation == generation else { return }
    let slotIndex = slots.firstIndex(where: { $0 === slot }) ?? -1
    slot.loadTask = nil
    let waiters = Array(slot.waiters.values)
    slot.waiters.removeAll()
    switch result {
    case .success(let composition):
      slot.state = .ready(composition)
      quickLookPreviewLogger.notice(
        "Load map completed slot \(slotIndex), generation \(generation), notifying \(waiters.count) waiter(s)."
      )
    case .failure:
      quickLookPreviewLogger.error(
        "Load map failed slot \(slotIndex), generation \(generation), notifying \(waiters.count) waiter(s)."
      )
      reset(slot)
    }
    for waiter in waiters {
      waiter(result)
    }
  }

  private func reset(_ slot: Slot) {
    slot.generation &+= 1
    slot.loadTask?.cancel()
    slot.loadTask = nil
    slot.waiters.removeAll()
    slot.state = .empty
    if slot.isAccessingSecurityScopedResource, let url = slot.url {
      url.stopAccessingSecurityScopedResource()
    }
    slot.url = nil
    slot.key = nil
    slot.isAccessingSecurityScopedResource = false
  }
}
