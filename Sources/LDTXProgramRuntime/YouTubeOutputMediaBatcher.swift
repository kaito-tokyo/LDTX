// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXOutputMedia
import LDTXYouTubeOutputProtocol

final class YouTubeOutputMediaBatcher: @unchecked Sendable {
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.YouTubeOutputMediaBatcher")
  private let sink: YouTubeOutputServiceProcessConnection
  private let context: YouTubeOutputContext
  private let failureHandler: @Sendable (Error) -> Void
  private var backlog = YouTubeOutputMediaBacklog()
  private var lastVideoFormat: YouTubeOutputH264Format?
  private var lastAudioFormat: YouTubeOutputAACFormat?
  private var scheduledFlush: DispatchWorkItem?
  private var isSending = false
  private var isFinished = false
  private var drainHandlers: [@Sendable () -> Void] = []

  init(
    sessionID: UUID,
    sink: YouTubeOutputServiceProcessConnection,
    failureHandler: @escaping @Sendable (Error) -> Void
  ) {
    context = YouTubeOutputContext(sessionID: sessionID, generation: 0)
    self.sink = sink
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
    queue.async { [self] in
      guard !isFinished else { return }
      let formatChanged = format != lastVideoFormat
      if formatChanged {
        lastVideoFormat = format
      }
      backlog.appendVideo(accessUnit, format: formatChanged ? format : nil)
      scheduleOrSend()
    }
  }

  func appendProgramAudio(_ packet: ProgramOutputAACPacket) {
    let format = packet.format
    let buffer = packet.accessUnit
    queue.async { [self] in
      guard !isFinished else { return }
      let changed = format != lastAudioFormat
      if changed { lastAudioFormat = format }
      backlog.appendAudio(buffer, format: changed ? format : nil)
      scheduleOrSend()
    }
  }

  func finish(completionHandler: @escaping @Sendable () -> Void) {
    queue.async { [self] in
      isFinished = true
      scheduledFlush?.cancel()
      scheduledFlush = nil
      drainHandlers.append(completionHandler)
      sendIfPossible()
      completeDrainIfNeeded()
    }
  }

  func cancel() {
    queue.async { [self] in
      isFinished = true
      scheduledFlush?.cancel()
      scheduledFlush = nil
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
      guard let self else { return }
      self.scheduledFlush = nil
      self.sendIfPossible()
    }
    scheduledFlush = work
    queue.asyncAfter(deadline: .now() + .milliseconds(20), execute: work)
  }

  private func sendIfPossible() {
    guard !isSending, let pending = backlog.takeBatch() else {
      completeDrainIfNeeded()
      return
    }
    isSending = true
    let batch = YouTubeOutputMediaBatch(
      context: context,
      sequence: 0,
      videoFormat: pending.videoFormat,
      video: pending.video,
      audioFormat: pending.audioFormat,
      audio: pending.audio
    )
    sink.uploadMediaBatch(batch) { [weak self] result in
      guard let self else { return }
      self.queue.async { [self] in
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
  }
}
