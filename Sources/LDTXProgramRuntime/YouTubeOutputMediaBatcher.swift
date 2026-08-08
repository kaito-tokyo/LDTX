// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXTaskQueue
import LDTXYouTubeOutputProtocol

final class YouTubeOutputMediaBatcher: @unchecked Sendable {
  private enum SubmissionError: Error {
    case backlogLimitExceeded
  }

  private final class SubmissionGate: @unchecked Sendable {
    enum Admission { case admitted, closed, overflowShouldFailNow(Bool) }

    private let lock = NSLock()
    private let clock = ContinuousClock()
    private var pendingCount = 0
    private var pendingInstants: [ContinuousClock.Instant] = []
    private var pendingHeadIndex = 0
    private var isClosed = false
    private var overflowPending = false
    private let maximumPendingCount: Int

    init(maximumPendingCount: Int = 10_000) {
      self.maximumPendingCount = maximumPendingCount
    }

    func admit() -> Admission {
      lock.withLock {
        guard !isClosed else { return .closed }
        let now = clock.now
        let oldestPendingInstant =
          pendingInstants.indices.contains(pendingHeadIndex)
          ? pendingInstants[pendingHeadIndex] : nil
        if pendingCount >= maximumPendingCount
          || oldestPendingInstant.map({ now - $0 >= .seconds(30) }) == true
        {
          isClosed = true
          overflowPending = true
          return .overflowShouldFailNow(pendingCount == 0)
        }
        pendingCount += 1
        pendingInstants.append(now)
        return .admitted
      }
    }

    func complete() -> Bool {
      lock.withLock {
        precondition(pendingCount > 0)
        pendingCount -= 1
        pendingHeadIndex += 1
        if pendingCount == 0 {
          pendingInstants.removeAll(keepingCapacity: true)
          pendingHeadIndex = 0
        } else if pendingHeadIndex >= 1_024, pendingHeadIndex * 2 >= pendingInstants.count {
          pendingInstants.removeFirst(pendingHeadIndex)
          pendingHeadIndex = 0
        }
        guard pendingCount == 0, overflowPending else { return false }
        overflowPending = false
        return true
      }
    }

    func close() {
      lock.withLock {
        isClosed = true
      }
    }

    func closeForFailure() -> Bool {
      lock.withLock {
        isClosed = true
        overflowPending = true
        return pendingCount == 0
      }
    }
  }

  private struct ResourceTask: @unchecked Sendable {
    let execute: @Sendable () -> Void
  }

  private let timerQueue = DispatchQueue(label: "tokyo.kaito.ldtx.youtube-output-batch-timers")
  private let resourceQueue: ResourceTaskQueue<ResourceTask>
  private let uploadMediaBatch:
    @Sendable (
      YouTubeOutputMediaBatch,
      @escaping @Sendable (Result<YouTubeOutputReply, Error>) -> Void
    ) -> Void
  private let context: YouTubeOutputContext
  private let failureHandler: @Sendable (Error) -> Void
  private let sharedVideoMemory: ProgramOutputSharedH264Service
  private let submissionGate: SubmissionGate
  private let submissionPostLock = NSLock()
  private let beforeMediaPost: @Sendable () -> Void
  private let beforeMediaExecution: @Sendable () -> Void
  private var backlog = YouTubeOutputMediaBacklog()
  private var lastVideoFormat: YouTubeOutputH264Format?
  private var scheduledFlush: DispatchWorkItem?
  private var isSending = false
  private var isFinished = false
  private var terminalFailure: Error?
  private var pendingAdmittedFailure: Error?
  private var drainHandlers: [@Sendable () -> Void] = []

  init(
    sessionID: UUID,
    revision: UInt64 = 0,
    sink: YouTubeOutputServiceProcessConnection,
    sharedVideoMemory: ProgramOutputSharedH264Service,
    failureHandler: @escaping @Sendable (Error) -> Void
  ) {
    context = YouTubeOutputContext(sessionID: sessionID, revision: revision)
    resourceQueue = Self.makeResourceQueue()
    uploadMediaBatch = { batch, completionHandler in
      sink.uploadMediaBatch(batch, completionHandler: completionHandler)
    }
    self.sharedVideoMemory = sharedVideoMemory
    self.failureHandler = failureHandler
    submissionGate = SubmissionGate()
    beforeMediaPost = {}
    beforeMediaExecution = {}
  }

  init(
    sessionID: UUID,
    revision: UInt64 = 0,
    sharedVideoMemory: ProgramOutputSharedH264Service,
    failureHandler: @escaping @Sendable (Error) -> Void,
    maximumPendingCount: Int = 10_000,
    beforeMediaPost: @escaping @Sendable () -> Void = {},
    beforeMediaExecution: @escaping @Sendable () -> Void = {},
    uploadMediaBatch:
      @escaping @Sendable (
        YouTubeOutputMediaBatch,
        @escaping @Sendable (Result<YouTubeOutputReply, Error>) -> Void
      ) -> Void
  ) {
    context = YouTubeOutputContext(sessionID: sessionID, revision: revision)
    resourceQueue = Self.makeResourceQueue()
    self.uploadMediaBatch = uploadMediaBatch
    self.sharedVideoMemory = sharedVideoMemory
    self.failureHandler = failureHandler
    submissionGate = SubmissionGate(maximumPendingCount: maximumPendingCount)
    self.beforeMediaPost = beforeMediaPost
    self.beforeMediaExecution = beforeMediaExecution
  }

  private static func makeResourceQueue() -> ResourceTaskQueue<ResourceTask> {
    ResourceTaskQueue(
      label: "tokyo.kaito.ldtx.youtube-output-media-batcher", logger: .disabled
    ) { task, _, _ in
      task.execute()
    }
  }

  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    let format: YouTubeOutputH264Format
    let accessUnit: YouTubeOutputH264AccessUnit
    do {
      format = try YouTubeOutputMediaSampleConverter.h264Format(from: sampleBuffer)
      accessUnit = try YouTubeOutputMediaSampleConverter.h264AccessUnit(from: sampleBuffer)
    } catch {
      failureHandler(error)
      return
    }
    postMedia { [self] in
      guard !isFinished else { return }
      let formatChanged = format != lastVideoFormat
      if formatChanged {
        lastVideoFormat = format
      }
      do {
        try backlog.appendVideo(accessUnit, format: formatChanged ? format : nil)
      } catch {
        failAfterAdmittedMediaDrain(error)
        return
      }
      scheduleOrSend()
    }
  }

  func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    let buffer: YouTubeOutputPCMBuffer
    do {
      buffer = try YouTubeOutputMediaSampleConverter.pcmBuffer(from: sampleBuffer)
    } catch {
      failureHandler(error)
      return
    }
    postMedia { [self] in
      guard !isFinished else { return }
      do {
        try backlog.appendAudio(buffer)
      } catch {
        failAfterAdmittedMediaDrain(error)
        return
      }
      scheduleOrSend()
    }
  }

  func finish(completionHandler: @escaping @Sendable () -> Void) {
    let accepted = submissionPostLock.withLock {
      submissionGate.close()
      return post { [self] in
        isFinished = true
        scheduledFlush?.cancel()
        scheduledFlush = nil
        drainHandlers.append(completionHandler)
        sendIfPossible()
        completeDrainIfNeeded()
      }
    }
    if !accepted {
      let queue = resourceQueue
      Task {
        await queue.finishAfterDraining()
        completionHandler()
      }
    }
  }

  func cancel(completionHandler: @escaping @Sendable () -> Void = {}) {
    let accepted = submissionPostLock.withLock {
      submissionGate.close()
      return post { [self] in
        isFinished = true
        scheduledFlush?.cancel()
        scheduledFlush = nil
        backlog = YouTubeOutputMediaBacklog()
        completeDrainIfNeeded()
        completionHandler()
      }
    }
    if !accepted {
      let queue = resourceQueue
      Task {
        await queue.stop()
        completionHandler()
      }
    }
  }

  private func scheduleOrSend() {
    if backlog.count >= 16 {
      scheduledFlush?.cancel()
      scheduledFlush = nil
      sendIfPossible()
      return
    }
    guard scheduledFlush == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      self?.post { [weak self] in
        guard let self else { return }
        scheduledFlush = nil
        sendIfPossible()
      }
    }
    scheduledFlush = work
    timerQueue.asyncAfter(deadline: .now() + .milliseconds(20), execute: work)
  }

  private func sendIfPossible() {
    guard !isSending else { return }
    guard let pending = backlog.takeBatch() else {
      completeDrainIfNeeded()
      return
    }
    isSending = true
    Task { [weak self] in
      guard let self else { return }
      let result:
        Result<(YouTubeOutputMediaBatch, ProgramOutputSharedH264Service.StoredBatch?), Error>
      do {
        result = .success(try await prepare(pending))
      } catch {
        result = .failure(error)
      }
      post { [weak self] in self?.sendPrepared(result) }
    }
  }

  private func prepare(
    _ pending: YouTubeOutputMediaBacklog.Batch
  ) async throws -> (YouTubeOutputMediaBatch, ProgramOutputSharedH264Service.StoredBatch?) {
    var video = pending.video
    let storedVideo: ProgramOutputSharedH264Service.StoredBatch?
    if video.isEmpty {
      storedVideo = nil
    } else {
      storedVideo = try await sharedVideoMemory.store(video.map(\.avccData))
      for index in video.indices {
        video[index].avccData = Data()
        video[index].sharedMemory = storedVideo?.slices[index]
      }
    }
    return (
      YouTubeOutputMediaBatch(
        context: context,
        sequence: 0,
        videoFormat: pending.videoFormat,
        video: video,
        audio: pending.audio
      ), storedVideo
    )
  }

  private func sendPrepared(
    _ result: Result<(YouTubeOutputMediaBatch, ProgramOutputSharedH264Service.StoredBatch?), Error>
  ) {
    guard case .success(let (batch, storedVideo)) = result else {
      isSending = false
      if case .failure(let error) = result {
        failureHandler(error)
      }
      completeDrainIfNeeded()
      return
    }
    uploadMediaBatch(batch) { [weak self] result in
      storedVideo?.release()
      guard let self else { return }
      self.post { [self] in
        isSending = false
        if case .failure(let error) = result {
          failureHandler(error)
        }
        sendIfPossible()
      }
    }
  }

  private func completeDrainIfNeeded() {
    guard isFinished, !isSending, backlog.isEmpty else { return }
    let terminalFailure = self.terminalFailure
    self.terminalFailure = nil
    let handlers = drainHandlers
    drainHandlers = []
    if let terminalFailure { failureHandler(terminalFailure) }
    for handler in handlers { handler() }
    let queue = resourceQueue
    Task { await queue.finishAfterDraining() }
  }

  private func failAfterDraining(_ error: Error) {
    guard !isFinished else { return }
    submissionGate.close()
    isFinished = true
    terminalFailure = error
    scheduledFlush?.cancel()
    scheduledFlush = nil
    sendIfPossible()
    completeDrainIfNeeded()
  }

  private func failAfterAdmittedMediaDrain(_ error: Error) {
    guard !isFinished else { return }
    if pendingAdmittedFailure == nil {
      pendingAdmittedFailure = error
    }
    if submissionGate.closeForFailure() {
      finishPendingAdmittedFailure()
    }
  }

  private func finishPendingAdmittedFailure() {
    let error = pendingAdmittedFailure ?? SubmissionError.backlogLimitExceeded
    pendingAdmittedFailure = nil
    failAfterDraining(error)
  }

  @discardableResult
  private func post(_ body: @escaping @Sendable () -> Void) -> Bool {
    resourceQueue.post(ResourceTask(execute: body))
  }

  private func postMedia(_ body: @escaping @Sendable () -> Void) {
    submissionPostLock.withLock {
      switch submissionGate.admit() {
      case .closed:
        return
      case .overflowShouldFailNow(let shouldFailNow):
        if shouldFailNow {
          post { [self] in failAfterDraining(SubmissionError.backlogLimitExceeded) }
        }
        return
      case .admitted:
        break
      }
      beforeMediaPost()
      let accepted = post { [self] in
        beforeMediaExecution()
        body()
        if submissionGate.complete() {
          finishPendingAdmittedFailure()
        }
      }
      if !accepted {
        _ = submissionGate.complete()
      }
    }
  }
}
