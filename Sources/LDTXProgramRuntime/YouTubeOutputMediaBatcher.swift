// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXTaskQueue
import LDTXYouTubeOutputProtocol
import OSLog

private let youtubeOutputMediaLogger = Logger(
  subsystem: "tokyo.kaito.ldtx", category: "DASHMedia")

final class YouTubeOutputMediaBatcher: @unchecked Sendable {
  private struct ResourceTask: @unchecked Sendable {
    let execute: @Sendable () -> Void
  }

  private let timerQueue = DispatchQueue(label: "tokyo.kaito.ldtx.youtube-output-batch-timers")
  private lazy var resourceQueue = ResourceTaskQueue<ResourceTask>(
    label: "tokyo.kaito.ldtx.youtube-output-media-batcher", logger: .disabled
  ) { task, _, _ in
    task.execute()
  }
  private let sink: YouTubeOutputServiceProcessConnection
  private let context: YouTubeOutputContext
  private let failureHandler: @Sendable (Error) -> Void
  private let sharedVideoMemory: ProgramOutputSharedH264Service
  private var backlog = YouTubeOutputMediaBacklog()
  private var lastVideoFormat: YouTubeOutputH264Format?
  private var scheduledFlush: DispatchWorkItem?
  private var isSending = false
  private var isFinished = false
  private var drainHandlers: [@Sendable () -> Void] = []

  init(
    sessionID: UUID,
    revision: UInt64 = 0,
    sink: YouTubeOutputServiceProcessConnection,
    sharedVideoMemory: ProgramOutputSharedH264Service,
    failureHandler: @escaping @Sendable (Error) -> Void
  ) {
    context = YouTubeOutputContext(sessionID: sessionID, revision: revision)
    self.sink = sink
    self.sharedVideoMemory = sharedVideoMemory
    self.failureHandler = failureHandler
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
    post { [self] in
      guard !isFinished else { return }
      let formatChanged = format != lastVideoFormat
      if formatChanged {
        lastVideoFormat = format
      }
      if let report = backlog.appendVideo(
        accessUnit, format: formatChanged ? format : nil)
      {
        logDrop(report)
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
    post { [self] in
      guard !isFinished else { return }
      backlog.appendAudio(buffer)
      scheduleOrSend()
    }
  }

  func finish(completionHandler: @escaping @Sendable () -> Void) {
    post { [self] in
      isFinished = true
      scheduledFlush?.cancel()
      scheduledFlush = nil
      for report in backlog.takePendingDropReports() { logDrop(report) }
      drainHandlers.append(completionHandler)
      sendIfPossible()
      completeDrainIfNeeded()
    }
  }

  func cancel() {
    post { [self] in
      isFinished = true
      scheduledFlush?.cancel()
      scheduledFlush = nil
      for report in backlog.takePendingDropReports() { logDrop(report) }
      backlog = YouTubeOutputMediaBacklog()
      completeDrainIfNeeded()
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
    for report in backlog.takeCompletedDropReports() { logDrop(report) }
    guard let pending = backlog.takeBatch() else {
      completeDrainIfNeeded()
      return
    }
    isSending = true
    Task { [weak self] in
      guard let self else { return }
      let result: Result<(YouTubeOutputMediaBatch, ProgramOutputSharedH264Service.StoredBatch?), Error>
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
    sink.uploadMediaBatch(batch) { [weak self] result in
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
    let handlers = drainHandlers
    drainHandlers = []
    for handler in handlers { handler() }
    let queue = resourceQueue
    Task { await queue.finishAfterDraining() }
  }

  private func logDrop(_ report: YouTubeOutputMediaBacklog.DropReport) {
    youtubeOutputMediaLogger.notice(
      "[event:dash.media.dropped] session=\(self.context.sessionID.uuidString, privacy: .public) revision=\(self.context.revision, privacy: .public) stage=workspaceBacklog reason=\(report.reason.rawValue, privacy: .public) videoUnits=\(report.videoUnitCount, privacy: .public) audioBuffers=\(report.audioBufferCount, privacy: .public) recoveredAtKeyFrame=\(report.recoveredAtKeyFrame, privacy: .public)"
    )
  }

  @discardableResult
  private func post(_ body: @escaping @Sendable () -> Void) -> Bool {
    resourceQueue.post(ResourceTask(execute: body))
  }
}
