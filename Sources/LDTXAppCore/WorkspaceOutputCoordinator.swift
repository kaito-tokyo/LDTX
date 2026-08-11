// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXAppUI
import LDTXDiagnostics
import LDTXProgramRuntime
import LDTXTaskQueue
import Observation

protocol SessionRecordServicing: AnyObject, Sendable {
  var packageDirectory: URL { get }
  var hasAcceptedFirstVideo: Bool { get }
  var recordsLandscapeOutput: Bool { get }
  var recordsPortraitOutput: Bool { get }
  @MainActor func start() throws
  func acceptFirstVideo(
    _ sampleBuffer: CMSampleBuffer,
    mainAudioFormatDescription: CMAudioFormatDescription?
  ) throws
  func acceptFirstPortraitVideo(
    _ sampleBuffer: CMSampleBuffer,
    mainAudioFormatDescription: CMAudioFormatDescription?
  ) throws
  func appendMainVideo(_ sampleBuffer: CMSampleBuffer)
  func appendMainAudioMix(_ sampleBuffer: CMSampleBuffer)
  func appendPortraitVideo(_ sampleBuffer: CMSampleBuffer)
  func appendPortraitAudioMix(_ sampleBuffer: CMSampleBuffer)
  func appendInputAudio(_ sampleBuffer: CMSampleBuffer, trackID: String)
  func sealInputAudio()
  @MainActor func stop(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void)
  @MainActor func finishAfterCut(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void)
  @MainActor func stopPreservingIncompletePackage(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void)
  @MainActor func abandonAfterMediaDrainTimeout()
  @MainActor func cancelBeforeFirstVideo(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void)
  func recordingTimelineMilliseconds() -> UInt64?
  func recordOutputStarted()
}

extension SessionRecordServicing {
  var recordsLandscapeOutput: Bool { true }
  var recordsPortraitOutput: Bool { false }
  func acceptFirstPortraitVideo(
    _ sampleBuffer: CMSampleBuffer,
    mainAudioFormatDescription _: CMAudioFormatDescription?
  ) throws {
    appendPortraitVideo(sampleBuffer)
  }
  func appendPortraitVideo(_: CMSampleBuffer) {}
  func appendPortraitAudioMix(_: CMSampleBuffer) {}
}

extension SessionRecordService: SessionRecordServicing {}

protocol YouTubeOutputWorkspaceServicing: AnyObject, Sendable {
  nonisolated func appendMainVideo(_ sampleBuffer: CMSampleBuffer)
  nonisolated func appendMainAudioMix(_ sampleBuffer: CMSampleBuffer)
  @MainActor func failMediaDelivery(_ error: Error)
  @MainActor func stop(
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void)
}

extension YouTubeOutputWorkspaceService: YouTubeOutputWorkspaceServicing {}

private final class WorkspaceRecordMediaCore: @unchecked Sendable {
  struct InputAudioCallback: @unchecked Sendable {
    fileprivate let service: any SessionRecordServicing
  }

  private struct SubmissionState {
    var isOpen = false
    var generation: UInt64 = 0
    var pendingCount = 0
    var pendingInstants: [ContinuousClock.Instant] = []
    var pendingHeadIndex = 0
    var didReportOverflow = false

    var oldestInstant: ContinuousClock.Instant? {
      guard pendingInstants.indices.contains(pendingHeadIndex) else { return nil }
      return pendingInstants[pendingHeadIndex]
    }

    mutating func append(at instant: ContinuousClock.Instant) {
      pendingCount += 1
      pendingInstants.append(instant)
    }

    mutating func complete() {
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
    }
  }
  private enum Sample: @unchecked Sendable {
    case video(CMSampleBuffer)
    case portraitVideo(CMSampleBuffer)
    case mainAudio(CMSampleBuffer)
    case portraitAudio(CMSampleBuffer)
    case inputAudio(CMSampleBuffer, trackID: String)
  }

  private struct Boundary {
    let id: UUID
    let operationID: UUID
    let previous: any SessionRecordServicing
    let firstPresentationTime: CMTime
    var latestPresentationTime: CMTime
    var samples: [Sample]
    var bufferedByteCount: Int
    var mainAudioFormatDescription: CMAudioFormatDescription?
    var portraitAudioFormatDescription: CMAudioFormatDescription?
    var landscapeFirstVideo: CMSampleBuffer?
    var portraitFirstVideo: CMSampleBuffer?
    var didRequestCommit = false
  }

  struct CommitResult {
    let previous: any SessionRecordServicing
    let current: any SessionRecordServicing
  }

  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.record-media", qos: .userInitiated)
  private let drainTimeout: Duration
  private let boundaryByteLimit: Int
  private let submissionLock = NSLock()
  private let clock = ContinuousClock()
  private var submissionState = SubmissionState()
  private var commitRequest: @MainActor @Sendable (UUID) -> Void = { _ in }
  private var eventHandler: @MainActor @Sendable (String) -> Void = { _ in }
  private var failureHandler: @MainActor @Sendable (Error) -> Void = { _ in }
  private var cutStateChanged: @MainActor @Sendable (Bool) -> Void = { _ in }
  private var activeService: (any SessionRecordServicing)?
  private var boundary: Boundary?
  private var isCutPending = false
  private var latestMainAudioFormatDescription: CMAudioFormatDescription?
  private var latestPortraitAudioFormatDescription: CMAudioFormatDescription?
  private let mainAudioFormatLock = NSLock()
  private var hasMainAudioFormat = false
  private let portraitAudioFormatLock = NSLock()
  private var hasPortraitAudioFormat = false
  private var pendingCommitRequestID: UUID?
  private let inputCallbackLock = NSLock()
  private var inputCallbackService: (any SessionRecordServicing)?
  private var inputCallbackCounts: [ObjectIdentifier: Int] = [:]
  private var inputCutFences: [ObjectIdentifier: CMTime] = [:]
  private var inputDrainHandlers: [ObjectIdentifier: @MainActor @Sendable () -> Void] = [:]

  init(
    drainTimeout: Duration = .seconds(30),
    boundaryByteLimit: Int = 256 * 1_024 * 1_024
  ) {
    self.drainTimeout = drainTimeout
    self.boundaryByteLimit = boundaryByteLimit
  }

  func hasRequiredAudioFormatDescriptions(for service: any SessionRecordServicing) -> Bool {
    (!service.recordsLandscapeOutput || mainAudioFormatLock.withLock { hasMainAudioFormat })
      && (!service.recordsPortraitOutput
        || portraitAudioFormatLock.withLock { hasPortraitAudioFormat })
  }

  func setCallbacks(
    commitRequest: @escaping @MainActor @Sendable (UUID) -> Void,
    eventHandler: @escaping @MainActor @Sendable (String) -> Void,
    failureHandler: @escaping @MainActor @Sendable (Error) -> Void,
    cutStateChanged: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    queue.sync {
      self.commitRequest = commitRequest
      self.eventHandler = eventHandler
      self.failureHandler = failureHandler
      self.cutStateChanged = cutStateChanged
    }
  }

  func install(_ service: any SessionRecordServicing) {
    submissionLock.withLock {
      submissionState = SubmissionState(
        isOpen: true, generation: submissionState.generation &+ 1)
    }
    inputCallbackLock.withLock {
      inputCallbackService = service
      inputCallbackCounts = [:]
      inputCutFences = [:]
      inputDrainHandlers = [:]
    }
    queue.sync {
      activeService = service
      boundary = nil
      isCutPending = false
      latestMainAudioFormatDescription = nil
      latestPortraitAudioFormatDescription = nil
      mainAudioFormatLock.withLock { hasMainAudioFormat = false }
      portraitAudioFormatLock.withLock { hasPortraitAudioFormat = false }
      pendingCommitRequestID = nil
    }
  }

  func synchronizeActiveIfNeeded(_ service: (any SessionRecordServicing)?) {
    queue.sync {
      guard let service else { return }
      guard activeService !== service else { return }
      activeService = service
      inputCallbackLock.withLock { inputCallbackService = service }
      boundary = nil
      isCutPending = false
      latestMainAudioFormatDescription = nil
      latestPortraitAudioFormatDescription = nil
      mainAudioFormatLock.withLock { hasMainAudioFormat = false }
      portraitAudioFormatLock.withLock { hasPortraitAudioFormat = false }
      pendingCommitRequestID = nil
      submissionLock.withLock {
        submissionState = SubmissionState(
          isOpen: true, generation: submissionState.generation &+ 1)
      }
    }
  }

  func reset(waitForMediaQueue: Bool = true) {
    submissionLock.withLock {
      submissionState.isOpen = false
      submissionState.generation &+= 1
    }
    inputCallbackLock.withLock {
      inputCallbackService = nil
      inputCallbackCounts = [:]
      inputCutFences = [:]
      inputDrainHandlers = [:]
    }
    let resetState: @Sendable () -> Void = { [self] in
      activeService = nil
      boundary = nil
      isCutPending = false
      latestMainAudioFormatDescription = nil
      latestPortraitAudioFormatDescription = nil
      mainAudioFormatLock.withLock { hasMainAudioFormat = false }
      portraitAudioFormatLock.withLock { hasPortraitAudioFormat = false }
      pendingCommitRequestID = nil
    }
    if waitForMediaQueue {
      queue.sync(execute: resetState)
    } else {
      queue.async(execute: resetState)
    }
  }

  func enqueueCutRequest(for service: any SessionRecordServicing) {
    queue.async { [self] in
      if activeService !== service {
        activeService = service
        inputCallbackLock.withLock { inputCallbackService = service }
        boundary = nil
        isCutPending = false
        latestMainAudioFormatDescription = nil
        latestPortraitAudioFormatDescription = nil
        mainAudioFormatLock.withLock { hasMainAudioFormat = false }
        portraitAudioFormatLock.withLock { hasPortraitAudioFormat = false }
        pendingCommitRequestID = nil
        submissionLock.withLock {
          submissionState = SubmissionState(
            isOpen: true, generation: submissionState.generation &+ 1)
        }
      }
      guard submissionLock.withLock({ submissionState.isOpen }),
        service.hasAcceptedFirstVideo, !isCutPending
      else { return }
      isCutPending = true
    }
  }

  func enqueueVideo(_ sampleBuffer: CMSampleBuffer, operationID: UUID) {
    let sample = WorkspaceSendableSampleBuffer(value: sampleBuffer)
    submit { [self, sample] in
      receiveVideo(sample.value, operationID: operationID)
      notifyPendingCommitRequestIfNeeded()
    }
  }

  func enqueueMainAudio(_ sampleBuffer: CMSampleBuffer) {
    let sample = WorkspaceSendableSampleBuffer(value: sampleBuffer)
    submit { [self, sample] in
      receiveMainAudio(sample.value)
      notifyPendingCommitRequestIfNeeded()
    }
  }

  func enqueuePortraitVideo(_ sampleBuffer: CMSampleBuffer, operationID: UUID) {
    let sample = WorkspaceSendableSampleBuffer(value: sampleBuffer)
    submit { [self, sample] in
      receivePortraitVideo(sample.value, operationID: operationID)
      notifyPendingCommitRequestIfNeeded()
    }
  }

  func enqueuePortraitAudio(_ sampleBuffer: CMSampleBuffer) {
    let sample = WorkspaceSendableSampleBuffer(value: sampleBuffer)
    submit { [self, sample] in
      receivePortraitAudio(sample.value)
      notifyPendingCommitRequestIfNeeded()
    }
  }

  func beginInputAudioCallback() -> InputAudioCallback? {
    inputCallbackLock.withLock {
      guard let inputCallbackService else { return nil }
      let id = ObjectIdentifier(inputCallbackService)
      inputCallbackCounts[id, default: 0] += 1
      return InputAudioCallback(service: inputCallbackService)
    }
  }

  func cancelInputAudioCallback(_ callback: InputAudioCallback) {
    completeInputAudioCallback(callback)
  }

  func enqueueInputAudio(
    _ sampleBuffer: CMSampleBuffer,
    trackID: String,
    callback: InputAudioCallback
  ) {
    let sample = WorkspaceSendableSampleBuffer(value: sampleBuffer)
    let accepted = submit { [self, sample] in
      receiveInputAudio(sample.value, trackID: trackID, callback: callback)
      completeInputAudioCallback(callback)
      notifyPendingCommitRequestIfNeeded()
    }
    if !accepted { cancelInputAudioCallback(callback) }
  }

  func deferFinalizationUntilInputAudioCallbacksDrain(
    for service: any SessionRecordServicing,
    _ handler: @escaping @MainActor @Sendable () -> Void
  ) -> Bool {
    inputCallbackLock.withLock { [self] in
      let id = ObjectIdentifier(service)
      guard inputCallbackCounts[id, default: 0] > 0 else {
        inputCutFences[id] = nil
        return false
      }
      inputDrainHandlers[id] = handler
      return true
    }
  }

  func receiveVideoSynchronously(_ sampleBuffer: CMSampleBuffer, operationID: UUID) -> UUID? {
    queue.sync {
      receiveVideo(sampleBuffer, operationID: operationID)
      return takePendingCommitRequest()
    }
  }

  func receiveMainAudioSynchronously(_ sampleBuffer: CMSampleBuffer) -> UUID? {
    queue.sync {
      receiveMainAudio(sampleBuffer)
      return takePendingCommitRequest()
    }
  }

  func receiveInputAudioSynchronously(_ sampleBuffer: CMSampleBuffer, trackID: String) -> UUID? {
    queue.sync {
      receiveInputAudio(sampleBuffer, trackID: trackID)
      return takePendingCommitRequest()
    }
  }

  func rollbackPendingCut() {
    queue.sync { rollbackBoundary() }
  }

  func closeAndDrain() async -> Result<Void, ProgramOutputMediaChannelError> {
    submissionLock.withLock { submissionState.isOpen = false }
    return await withCheckedContinuation { continuation in
      let race = RecordMediaDrainRace(continuation: continuation)
      queue.async { race.finish(.success(())) }
      Task { [drainTimeout] in
        try? await Task.sleep(for: drainTimeout)
        race.finish(.failure(.drainTimedOut))
      }
    }
  }

  func enqueueCommit(
    boundaryID: UUID,
    operationID: UUID,
    replacement: any SessionRecordServicing,
    completionHandler: @escaping @MainActor @Sendable (Result<CommitResult?, Error>) -> Void
  ) {
    queue.async { [self] in
      let result = Result {
        try commitOnMediaQueue(
          boundaryID: boundaryID, operationID: operationID, replacement: replacement)
      }
      Task { @MainActor in completionHandler(result) }
    }
  }

  private func commitOnMediaQueue(
    boundaryID: UUID,
    operationID: UUID,
    replacement: any SessionRecordServicing
  ) throws -> CommitResult? {
    guard let boundary, boundary.id == boundaryID else { return nil }
    guard boundary.operationID == operationID, activeService === boundary.previous else {
      rollbackBoundary()
      return nil
    }
    do {
      if boundary.previous.recordsLandscapeOutput {
        guard let firstVideo = boundary.landscapeFirstVideo,
          let audioFormat = boundary.mainAudioFormatDescription
        else { throw WorkspaceRecordMediaCoreError.firstVideoMissing }
        try replacement.acceptFirstVideo(
          firstVideo,
          mainAudioFormatDescription: audioFormat)
      }
      if boundary.previous.recordsPortraitOutput {
        guard let firstVideo = boundary.portraitFirstVideo,
          let audioFormat = boundary.portraitAudioFormatDescription
        else { throw WorkspaceRecordMediaCoreError.firstVideoMissing }
        try replacement.acceptFirstPortraitVideo(
          firstVideo,
          mainAudioFormatDescription: audioFormat)
      }
    } catch {
      rollbackBoundary()
      throw error
    }
    activeService = replacement
    inputCallbackLock.withLock {
      inputCallbackService = replacement
      inputCutFences[ObjectIdentifier(boundary.previous)] = boundary.firstPresentationTime
    }
    self.boundary = nil
    isCutPending = false
    for sample in boundary.samples {
      if Self.precedesCanvasStart(sample, boundary: boundary) {
        deliver(sample, to: boundary.previous)
        continue
      }
      switch sample {
      case .video(let buffer) where buffer === boundary.landscapeFirstVideo:
        continue
      case .portraitVideo(let buffer) where buffer === boundary.portraitFirstVideo:
        continue
      default:
        deliver(sample, to: replacement)
      }
    }
    return CommitResult(previous: boundary.previous, current: replacement)
  }

  private static func precedesCanvasStart(_ sample: Sample, boundary: Boundary) -> Bool {
    switch sample {
    case .video(let buffer), .mainAudio(let buffer):
      return precedes(buffer, boundary.landscapeFirstVideo)
    case .portraitVideo(let buffer), .portraitAudio(let buffer):
      return precedes(buffer, boundary.portraitFirstVideo)
    case .inputAudio:
      return false
    }
  }

  private static func precedes(
    _ sampleBuffer: CMSampleBuffer,
    _ firstVideo: CMSampleBuffer?
  ) -> Bool {
    guard let firstVideo else { return false }
    let presentationTime = sampleBuffer.presentationTimeStamp
    let firstPresentationTime = firstVideo.presentationTimeStamp
    return presentationTime.isNumeric && firstPresentationTime.isNumeric
      && CMTimeCompare(presentationTime, firstPresentationTime) < 0
  }

  func enqueueRollbackPendingCut() { queue.async { [self] in rollbackBoundary() } }

  func waitForPendingOperations() async {
    await withCheckedContinuation { continuation in
      queue.async {
        Task { @MainActor in continuation.resume() }
      }
    }
  }

  private func receiveVideo(_ sampleBuffer: CMSampleBuffer, operationID: UUID) {
    if boundary != nil {
      appendToBoundary(.video(sampleBuffer))
      return
    }
    guard isCutPending, Self.isSyncVideoSample(sampleBuffer), let activeService else {
      self.activeService?.appendMainVideo(sampleBuffer)
      return
    }
    let boundary = Boundary(
      id: UUID(),
      operationID: operationID,
      previous: activeService,
      firstPresentationTime: sampleBuffer.presentationTimeStamp,
      latestPresentationTime: sampleBuffer.presentationTimeStamp,
      samples: [.video(sampleBuffer)],
      bufferedByteCount: Self.byteCount(of: sampleBuffer),
      mainAudioFormatDescription: latestMainAudioFormatDescription,
      portraitAudioFormatDescription: latestPortraitAudioFormatDescription,
      landscapeFirstVideo: sampleBuffer,
      portraitFirstVideo: nil)
    self.boundary = boundary
    guard boundary.bufferedByteCount <= boundaryByteLimit else {
      failBoundaryForByteLimit()
      return
    }
    requestCommitIfReady(boundary.id)
  }

  private func receivePortraitVideo(_ sampleBuffer: CMSampleBuffer, operationID: UUID) {
    if boundary != nil {
      appendToBoundary(.portraitVideo(sampleBuffer))
      return
    }
    guard isCutPending, Self.isSyncVideoSample(sampleBuffer), let activeService else {
      self.activeService?.appendPortraitVideo(sampleBuffer)
      return
    }
    let boundary = Boundary(
      id: UUID(),
      operationID: operationID,
      previous: activeService,
      firstPresentationTime: sampleBuffer.presentationTimeStamp,
      latestPresentationTime: sampleBuffer.presentationTimeStamp,
      samples: [.portraitVideo(sampleBuffer)],
      bufferedByteCount: Self.byteCount(of: sampleBuffer),
      mainAudioFormatDescription: latestMainAudioFormatDescription,
      portraitAudioFormatDescription: latestPortraitAudioFormatDescription,
      landscapeFirstVideo: nil,
      portraitFirstVideo: sampleBuffer)
    self.boundary = boundary
    guard boundary.bufferedByteCount <= boundaryByteLimit else {
      failBoundaryForByteLimit()
      return
    }
    requestCommitIfReady(boundary.id)
  }

  private func receiveMainAudio(_ sampleBuffer: CMSampleBuffer) {
    if let formatDescription = sampleBuffer.formatDescription {
      latestMainAudioFormatDescription = formatDescription
      mainAudioFormatLock.withLock { hasMainAudioFormat = true }
    }
    if boundary != nil {
      appendToBoundary(.mainAudio(sampleBuffer))
    } else {
      activeService?.appendMainAudioMix(sampleBuffer)
    }
  }

  private func receivePortraitAudio(_ sampleBuffer: CMSampleBuffer) {
    if let formatDescription = sampleBuffer.formatDescription {
      latestPortraitAudioFormatDescription = formatDescription
      portraitAudioFormatLock.withLock { hasPortraitAudioFormat = true }
    }
    if boundary != nil {
      appendToBoundary(.portraitAudio(sampleBuffer))
    } else {
      activeService?.appendPortraitAudioMix(sampleBuffer)
    }
  }

  private func receiveInputAudio(
    _ sampleBuffer: CMSampleBuffer,
    trackID: String,
    callback: InputAudioCallback? = nil
  ) {
    if let callback {
      let callbackServiceID = ObjectIdentifier(callback.service)
      if let fence = inputCallbackLock.withLock({ inputCutFences[callbackServiceID] }),
        sampleBuffer.presentationTimeStamp.isNumeric, fence.isNumeric,
        CMTimeCompare(sampleBuffer.presentationTimeStamp, fence) < 0
      {
        callback.service.appendInputAudio(sampleBuffer, trackID: trackID)
        return
      }
    }
    if boundary != nil {
      appendToBoundary(.inputAudio(sampleBuffer, trackID: trackID))
    } else {
      activeService?.appendInputAudio(sampleBuffer, trackID: trackID)
    }
  }

  private func appendToBoundary(_ sample: Sample) {
    guard var boundary else { return }
    let presentationTime = presentationTime(of: sample)
    if Self.isAudio(sample), presentationTime.isNumeric,
      boundary.firstPresentationTime.isNumeric,
      CMTimeCompare(presentationTime, boundary.firstPresentationTime) < 0
    {
      deliver(sample, to: boundary.previous)
      return
    }
    boundary.samples.append(sample)
    let sampleByteCount = Self.byteCount(of: sampleBuffer(of: sample))
    let (bufferedByteCount, didOverflow) = boundary.bufferedByteCount.addingReportingOverflow(
      sampleByteCount)
    boundary.bufferedByteCount = didOverflow ? Int.max : bufferedByteCount
    if case .mainAudio(let buffer) = sample, let format = buffer.formatDescription {
      boundary.mainAudioFormatDescription = format
    }
    if case .portraitAudio(let buffer) = sample, let format = buffer.formatDescription {
      boundary.portraitAudioFormatDescription = format
    }
    if case .video(let buffer) = sample, boundary.landscapeFirstVideo == nil,
      Self.isSyncVideoSample(buffer)
    {
      boundary.landscapeFirstVideo = buffer
    }
    if case .portraitVideo(let buffer) = sample, boundary.portraitFirstVideo == nil,
      Self.isSyncVideoSample(buffer)
    {
      boundary.portraitFirstVideo = buffer
    }
    if presentationTime.isNumeric,
      !boundary.latestPresentationTime.isNumeric
        || CMTimeCompare(presentationTime, boundary.latestPresentationTime) > 0
    {
      boundary.latestPresentationTime = presentationTime
    }
    self.boundary = boundary
    requestCommitIfReady(boundary.id)
    guard boundary.bufferedByteCount <= boundaryByteLimit else {
      failBoundaryForByteLimit()
      return
    }
    guard boundary.firstPresentationTime.isNumeric, boundary.latestPresentationTime.isNumeric,
      CMTimeCompare(
        CMTimeSubtract(boundary.latestPresentationTime, boundary.firstPresentationTime),
        CMTime(seconds: 60, preferredTimescale: 600)) > 0
    else { return }
    rollbackBoundary()
    Task { @MainActor [eventHandler] in
      eventHandler(
        "Cut failed; recording continues: Cut commit exceeded the 60-second boundary buffer limit")
    }
  }

  private func requestCommitIfReady(_ boundaryID: UUID) {
    guard var boundary, boundary.id == boundaryID, !boundary.didRequestCommit else { return }
    if boundary.previous.recordsLandscapeOutput {
      guard boundary.landscapeFirstVideo != nil,
        boundary.mainAudioFormatDescription != nil
      else { return }
    }
    if boundary.previous.recordsPortraitOutput {
      guard boundary.portraitFirstVideo != nil,
        boundary.portraitAudioFormatDescription != nil
      else { return }
    }
    boundary.didRequestCommit = true
    self.boundary = boundary
    pendingCommitRequestID = boundaryID
  }

  private func failBoundaryForByteLimit() {
    rollbackBoundary()
    Task { @MainActor [eventHandler] in
      eventHandler("Cut failed; recording continues: Cut commit exceeded the boundary byte limit")
    }
  }

  private func takePendingCommitRequest() -> UUID? {
    defer { pendingCommitRequestID = nil }
    return pendingCommitRequestID
  }

  private func notifyPendingCommitRequestIfNeeded() {
    guard let boundaryID = takePendingCommitRequest() else { return }
    Task { @MainActor [commitRequest] in commitRequest(boundaryID) }
  }

  @discardableResult
  private func submit(_ operation: @escaping @Sendable () -> Void) -> Bool {
    let now = clock.now
    let accepted = submissionLock.withLock { () -> Bool in
      guard submissionState.isOpen else { return false }
      let exceededCount = submissionState.pendingCount >= 10_000
      let exceededDuration =
        submissionState.oldestInstant.map {
          now - $0 >= .seconds(30)
        } ?? false
      if exceededCount || exceededDuration {
        submissionState.isOpen = false
        guard !submissionState.didReportOverflow else { return false }
        submissionState.didReportOverflow = true
        let generation = submissionState.generation
        let failureHandler = self.failureHandler
        Task { @MainActor [weak self] in
          guard let self,
            self.submissionLock.withLock({ self.submissionState.generation == generation })
          else { return }
          failureHandler(ProgramOutputMediaChannelError.backlogLimitExceeded)
        }
        return false
      }
      submissionState.append(at: now)
      return true
    }
    guard accepted else { return false }
    queue.async { [self] in
      operation()
      submissionLock.withLock { submissionState.complete() }
    }
    return true
  }

  private func completeInputAudioCallback(_ callback: InputAudioCallback) {
    let id = ObjectIdentifier(callback.service)
    let handler: (@MainActor @Sendable () -> Void)? = inputCallbackLock.withLock {
      guard let count = inputCallbackCounts[id], count > 0 else { return nil }
      let remaining = count - 1
      if remaining > 0 {
        inputCallbackCounts[id] = remaining
        return nil
      }
      inputCallbackCounts[id] = nil
      inputCutFences[id] = nil
      return inputDrainHandlers.removeValue(forKey: id)
    }
    if let handler { Task { @MainActor in handler() } }
  }

  private func rollbackBoundary() {
    guard let boundary else {
      isCutPending = false
      return
    }
    self.boundary = nil
    isCutPending = false
    pendingCommitRequestID = nil
    let cutStateChanged = self.cutStateChanged
    Task { @MainActor in cutStateChanged(false) }
    if activeService === boundary.previous {
      for sample in boundary.samples { deliver(sample, to: boundary.previous) }
    }
  }

  private func deliver(_ sample: Sample, to service: any SessionRecordServicing) {
    switch sample {
    case .video(let buffer): service.appendMainVideo(buffer)
    case .portraitVideo(let buffer): service.appendPortraitVideo(buffer)
    case .mainAudio(let buffer): service.appendMainAudioMix(buffer)
    case .portraitAudio(let buffer): service.appendPortraitAudioMix(buffer)
    case .inputAudio(let buffer, let trackID):
      service.appendInputAudio(buffer, trackID: trackID)
    }
  }

  private func presentationTime(of sample: Sample) -> CMTime {
    sampleBuffer(of: sample).presentationTimeStamp
  }

  private func sampleBuffer(of sample: Sample) -> CMSampleBuffer {
    switch sample {
    case .video(let buffer), .portraitVideo(let buffer), .mainAudio(let buffer),
      .portraitAudio(let buffer), .inputAudio(let buffer, _):
      buffer
    }
  }

  private static func isAudio(_ sample: Sample) -> Bool {
    switch sample {
    case .video, .portraitVideo: false
    case .mainAudio, .portraitAudio, .inputAudio: true
    }
  }

  private static func byteCount(of sampleBuffer: CMSampleBuffer) -> Int {
    let sampleSize = CMSampleBufferGetTotalSampleSize(sampleBuffer)
    let dataSize = sampleBuffer.dataBuffer.map(CMBlockBufferGetDataLength) ?? 0
    return max(sampleSize, dataSize)
  }

  private static func isSyncVideoSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return false }
    let attachments =
      CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    return attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
  }
}

private enum WorkspaceRecordMediaCoreError: Error {
  case firstVideoMissing
  case mainAudioFormatMissing
}

private final class WorkspaceRecordMediaCoreSlot: @unchecked Sendable {
  private let lock = NSLock()
  private var core: WorkspaceRecordMediaCore

  init(_ core: WorkspaceRecordMediaCore) { self.core = core }

  func current() -> WorkspaceRecordMediaCore { lock.withLock { core } }

  func replace(with core: WorkspaceRecordMediaCore) {
    lock.withLock { self.core = core }
  }
}

private final class RecordMediaDrainRace: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation:
    CheckedContinuation<Result<Void, ProgramOutputMediaChannelError>, Never>?

  init(
    continuation: CheckedContinuation<Result<Void, ProgramOutputMediaChannelError>, Never>
  ) {
    self.continuation = continuation
  }

  func finish(_ result: Result<Void, ProgramOutputMediaChannelError>) {
    let continuation = lock.withLock {
      let continuation = self.continuation
      self.continuation = nil
      return continuation
    }
    continuation?.resume(returning: result)
  }
}

private final class RecordFinalizationRace: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<SessionRecordFinalizationResult, Never>?
  private var timeoutTask: Task<Void, Never>?

  init(continuation: CheckedContinuation<SessionRecordFinalizationResult, Never>) {
    self.continuation = continuation
  }

  func installTimeoutTask(_ task: Task<Void, Never>) {
    let shouldCancel = lock.withLock {
      guard continuation != nil else { return true }
      timeoutTask = task
      return false
    }
    if shouldCancel { task.cancel() }
  }

  func finish(_ result: SessionRecordFinalizationResult) {
    let (continuation, timeoutTask) = lock.withLock {
      let continuation = self.continuation
      self.continuation = nil
      let timeoutTask = self.timeoutTask
      self.timeoutTask = nil
      return (continuation, timeoutTask)
    }
    timeoutTask?.cancel()
    continuation?.resume(returning: result)
  }
}

@MainActor
@Observable
final class WorkspaceEventCoordinator {
  @ObservationIgnored private let queue: EventTaskQueue
  @ObservationIgnored private var generation: UInt64 = 0
  var isLocked = false

  init(logger: EventTaskLogger) {
    queue = EventTaskQueue(label: "tokyo.kaito.ldtx.workspace.events", logger: logger)
  }

  @discardableResult
  func enqueue(
    _ operation: @escaping @MainActor @Sendable (EventTaskLogger) async -> Void
  ) -> Bool {
    let completionState = WorkspaceEventCompletion()
    generation &+= 1
    let generation = generation
    isLocked = true
    let accepted = queue.enqueue(
      onDiscard: {
        Task { @MainActor in completionState.finish() }
      },
      { completion in
        { _, logger in
          Task { @MainActor in
            defer {
              completionState.finish()
              completion()
            }
            await operation(logger)
          }
        }
      })
    if !accepted { completionState.finish() }

    Task { @MainActor [weak self] in
      guard let self else { return }
      await completionState.wait()
      try? await Task.sleep(for: .milliseconds(200))
      guard self.generation == generation else { return }
      self.isLocked = false
    }
    return accepted
  }

  func interrupt() async {
    generation &+= 1
    await withCheckedContinuation { continuation in
      queue.stop { continuation.resume() }
    }
    isLocked = false
  }
}

private final class WorkspaceRecordCutBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private var remainingArrivalCount: Int
  private var waiters: [DispatchSemaphore] = []
  private var isCancelled = false
  private let action: @Sendable () -> Void

  init(arrivalCount: Int, action: @escaping @Sendable () -> Void) {
    precondition(arrivalCount > 0)
    remainingArrivalCount = arrivalCount
    self.action = action
  }

  func arriveAndWait() {
    let result = lock.withLock { () -> (DispatchSemaphore?, [DispatchSemaphore]) in
      guard !isCancelled else { return (nil, []) }
      remainingArrivalCount -= 1
      if remainingArrivalCount == 0 {
        action()
        let waiters = self.waiters
        self.waiters.removeAll()
        return (nil, waiters)
      }
      let waiter = DispatchSemaphore(value: 0)
      waiters.append(waiter)
      return (waiter, [])
    }
    for waiter in result.1 { waiter.signal() }
    result.0?.wait()
  }

  func cancel() {
    let waiters = lock.withLock {
      isCancelled = true
      let waiters = self.waiters
      self.waiters.removeAll()
      return waiters
    }
    for waiter in waiters { waiter.signal() }
  }
}

@MainActor
@Observable
final class WorkspaceOutputCoordinator {
  struct RecordAuxiliaryLease {
    let id: UUID
    let packageDirectory: URL
    let timelineMilliseconds: UInt64?
  }
  @ObservationIgnored private let sleepInhibitor: OutputSleepInhibitor
  var currentSession: ActiveDualProgramOutputSession?
  var currentMediaHub: ProgramOutputMediaHub?
  var portraitMediaHub: ProgramOutputMediaHub?
  var recordService: (any SessionRecordServicing)?
  var youtubeService: (any YouTubeOutputWorkspaceServicing)?
  var sharedH264Service: ProgramOutputSharedH264Service?
  @ObservationIgnored private var recordSubscription: ProgramOutputMediaHub.Subscription?
  @ObservationIgnored private var portraitRecordSubscription: ProgramOutputMediaHub.Subscription?
  @ObservationIgnored private var recordMediaHub: ProgramOutputMediaHub?
  @ObservationIgnored private var recordSubscriptionGeneration: UUID?
  @ObservationIgnored private var recordInputAudioSubscriptions:
    [WorkspaceCaptureSessionCoordinator.AudioSubscription] = []
  @ObservationIgnored private weak var recordCaptureSessionCoordinator:
    WorkspaceCaptureSessionCoordinator?
  @ObservationIgnored private var youtubeSubscription: ProgramOutputMediaHub.Subscription?
  var youtubeOutputServiceProcess: YouTubeOutputServiceProcessClient?
  var lifecycleState: OutputSessionControlState = .idle {
    didSet {
      switch lifecycleState {
      case .idle, .readyToRestart:
        sleepInhibitor.stop()
      case .starting, .running, .pausing, .stopping:
        sleepInhibitor.start()
      }
    }
  }
  var isRecordFinalizing = false
  var isRecordCutCoolingDown = false
  var isProgramRuntimeTransitioning = false
  var operationID = UUID()
  var activeMode: CaptureOutputMode?
  @ObservationIgnored private var makeRecordService: (() throws -> any SessionRecordServicing)?
  @ObservationIgnored private var finalizingRecordServices:
    [ObjectIdentifier: any SessionRecordServicing] = [:]
  @ObservationIgnored private var auxiliaryRecordServices: [UUID: any SessionRecordServicing] = [:]
  @ObservationIgnored private var deferredRecordFinalizers:
    [ObjectIdentifier: any SessionRecordServicing] = [:]
  @ObservationIgnored private var cancellingRecordServices:
    [ObjectIdentifier: any SessionRecordServicing] = [:]
  @ObservationIgnored private var activeRecordStopFailure: (any Error)?
  @ObservationIgnored private var didRecordMediaDrainTimeout = false
  @ObservationIgnored private var recordFinalizationFailure: (any Error)?
  @ObservationIgnored private var cutCooldownTask: Task<Void, Never>?
  @ObservationIgnored private var isRecordCutPending = false
  @ObservationIgnored private var recordEventHandler: (@MainActor @Sendable (String) -> Void)?
  @ObservationIgnored private var recordFailureHandler: (@MainActor @Sendable (Error) -> Void)?
  @ObservationIgnored private var enqueueRecordControl:
    ((@escaping @MainActor @Sendable () -> Void) -> Bool)?
  @ObservationIgnored nonisolated private let recordMediaCoreSlot: WorkspaceRecordMediaCoreSlot
  @ObservationIgnored private let recordMediaDrainTimeout: Duration
  @ObservationIgnored private let recordCutBoundaryByteLimit: Int
  @ObservationIgnored private let recordFinalizerTimeout: Duration
  @ObservationIgnored private let waitForRecordCutCooldown: @Sendable () async throws -> Void
  @ObservationIgnored private let copyRecordInputAudioSample:
    @Sendable (CMSampleBuffer) throws -> ProgramOwnedPCMSampleBuffer

  init(
    sleepInhibitor: OutputSleepInhibitor = OutputSleepInhibitor(),
    recordMediaDrainTimeout: Duration = .seconds(30),
    recordCutBoundaryByteLimit: Int = 256 * 1_024 * 1_024,
    recordFinalizerTimeout: Duration = .seconds(30),
    copyRecordInputAudioSample:
      @escaping @Sendable (CMSampleBuffer) throws ->
      ProgramOwnedPCMSampleBuffer = { try ProgramOwnedPCMSampleBuffer(copying: $0) },
    waitForRecordCutCooldown: @escaping @Sendable () async throws -> Void = {
      try await ContinuousClock().sleep(for: .seconds(2))
    }
  ) {
    self.sleepInhibitor = sleepInhibitor
    let recordMediaCore = WorkspaceRecordMediaCore(
      drainTimeout: recordMediaDrainTimeout,
      boundaryByteLimit: recordCutBoundaryByteLimit)
    recordMediaCoreSlot = WorkspaceRecordMediaCoreSlot(recordMediaCore)
    self.recordMediaDrainTimeout = recordMediaDrainTimeout
    self.recordCutBoundaryByteLimit = recordCutBoundaryByteLimit
    self.recordFinalizerTimeout = recordFinalizerTimeout
    self.copyRecordInputAudioSample = copyRecordInputAudioSample
    self.waitForRecordCutCooldown = waitForRecordCutCooldown
    configureRecordMediaCore(recordMediaCore)
  }

  func beginStarting() -> UUID {
    let operationID = UUID()
    self.operationID = operationID
    lifecycleState = .starting
    return operationID
  }

  func invalidateOperations(for state: OutputSessionControlState) -> UUID {
    if state == .stopping || state == .pausing {
      cancelRecordCut(rollbackMediaCore: false)
    }
    let operationID = UUID()
    self.operationID = operationID
    lifecycleState = state
    return operationID
  }

  func resetSession() {
    let waitForRecordMediaQueue = !didRecordMediaDrainTimeout
    let recordMediaCore = recordMediaCoreSlot.current()
    sleepInhibitor.stop()
    currentSession = nil
    currentMediaHub = nil
    portraitMediaHub = nil
    recordService = nil
    youtubeService = nil
    sharedH264Service = nil
    recordSubscription = nil
    portraitRecordSubscription = nil
    recordMediaHub = nil
    recordSubscriptionGeneration = nil
    if let recordCaptureSessionCoordinator {
      recordInputAudioSubscriptions.forEach(recordCaptureSessionCoordinator.unsubscribeAudio)
    }
    recordInputAudioSubscriptions = []
    recordCaptureSessionCoordinator = nil
    youtubeSubscription = nil
    activeMode = nil
    isRecordFinalizing = false
    isRecordCutCoolingDown = false
    isProgramRuntimeTransitioning = false
    makeRecordService = nil
    finalizingRecordServices = [:]
    auxiliaryRecordServices = [:]
    deferredRecordFinalizers = [:]
    cancellingRecordServices = [:]
    activeRecordStopFailure = nil
    didRecordMediaDrainTimeout = false
    recordFinalizationFailure = nil
    cutCooldownTask?.cancel()
    cutCooldownTask = nil
    isRecordCutPending = false
    recordEventHandler = nil
    recordFailureHandler = nil
    enqueueRecordControl = nil
    recordMediaCore.reset(waitForMediaQueue: waitForRecordMediaQueue)
    if !waitForRecordMediaQueue {
      let replacement = WorkspaceRecordMediaCore(
        drainTimeout: recordMediaDrainTimeout,
        boundaryByteLimit: recordCutBoundaryByteLimit)
      configureRecordMediaCore(replacement)
      recordMediaCoreSlot.replace(with: replacement)
    }
  }

  private func configureRecordMediaCore(_ recordMediaCore: WorkspaceRecordMediaCore) {
    recordMediaCore.setCallbacks(
      commitRequest: { [weak self, weak recordMediaCore] boundaryID in
        guard let recordMediaCore else { return }
        self?.enqueueRecordMediaCommit(boundaryID, mediaCore: recordMediaCore)
      },
      eventHandler: { [weak self, weak recordMediaCore] message in
        guard let self, let recordMediaCore,
          self.recordMediaCoreSlot.current() === recordMediaCore
        else { return }
        self.recordEventHandler?(message)
      },
      failureHandler: { [weak self, weak recordMediaCore] error in
        guard let self, let recordMediaCore,
          self.recordMediaCoreSlot.current() === recordMediaCore
        else { return }
        self.activeRecordStopFailure = error
        Task { @MainActor in
          _ = await self.stopRecordServicePreservingIncompletePackage()
        }
      },
      cutStateChanged: { [weak self, weak recordMediaCore] isPending in
        guard let self, let recordMediaCore,
          self.recordMediaCoreSlot.current() === recordMediaCore
        else { return }
        self.isRecordCutPending = isPending
      })
  }

  func installRecordInputAudioSubscriptions(
    tracks: [SessionRecordAudioTrack],
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    failureHandler: @escaping @MainActor @Sendable (Error) -> Void,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    let recordMediaCore = recordMediaCoreSlot.current()
    recordMediaCore.synchronizeActiveIfNeeded(recordService)
    recordCaptureSessionCoordinator = captureSessionCoordinator
    guard !tracks.isEmpty else {
      completionHandler()
      return
    }
    let group = DispatchGroup()
    for track in tracks {
      group.enter()
      let subscription = captureSessionCoordinator.subscribeAudio(
        deviceID: track.deviceID,
        failureHandler: { failure in
          Task { @MainActor in failureHandler(failure) }
        },
        sampleHandler: { [weak self] sampleBuffer in
          guard let self else { return }
          guard let callback = recordMediaCore.beginInputAudioCallback() else { return }
          let sample: ProgramOwnedPCMSampleBuffer
          do {
            sample = try self.copyRecordInputAudioSample(sampleBuffer)
          } catch {
            recordMediaCore.cancelInputAudioCallback(callback)
            Task { @MainActor in failureHandler(error) }
            return
          }
          recordMediaCore.enqueueInputAudio(
            sample.value, trackID: track.trackID, callback: callback)
        },
        completionHandler: { result in
          if case .failure(let error) = result {
            Task { @MainActor in failureHandler(error) }
          }
          group.leave()
        })
      recordInputAudioSubscriptions.append(subscription)
    }
    notifyRecordInputAudioSubscriptionCompletion(group, completionHandler: completionHandler)
  }

  private func removeRecordInputAudioSubscriptions() {
    if let recordCaptureSessionCoordinator {
      recordInputAudioSubscriptions.forEach(recordCaptureSessionCoordinator.unsubscribeAudio)
    }
    recordInputAudioSubscriptions = []
    recordCaptureSessionCoordinator = nil
  }

  private func drainAndRemoveRecordInputAudioSubscriptions() async {
    let subscriptions = recordInputAudioSubscriptions
    let captureSessionCoordinator = recordCaptureSessionCoordinator
    recordInputAudioSubscriptions = []
    recordCaptureSessionCoordinator = nil
    if let captureSessionCoordinator, !subscriptions.isEmpty {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let group = DispatchGroup()
        for subscription in subscriptions {
          group.enter()
          captureSessionCoordinator.unsubscribeAudio(
            subscription,
            completionHandler: { group.leave() })
        }
        resumeWhenDispatchGroupFinishes(group, continuation: continuation)
      }
    }
  }

  func installRecordService(
    _ service: any SessionRecordServicing,
    on hub: ProgramOutputMediaHub,
    portraitHub: ProgramOutputMediaHub? = nil,
    makeNext: @escaping () throws -> any SessionRecordServicing,
    enqueueControl: @escaping (@escaping @MainActor @Sendable () -> Void) -> Bool,
    failureHandler: @escaping @MainActor @Sendable (Error) -> Void = { _ in },
    eventHandler: @escaping @MainActor @Sendable (String) -> Void
  ) {
    let recordMediaCore = recordMediaCoreSlot.current()
    recordService = service
    recordMediaCore.install(service)
    makeRecordService = makeNext
    enqueueRecordControl = enqueueControl
    recordFailureHandler = failureHandler
    recordEventHandler = eventHandler
    let recordOperationID = operationID
    let subscriptionGeneration = UUID()
    recordMediaHub = hub
    portraitMediaHub = portraitHub
    recordSubscriptionGeneration = subscriptionGeneration
    recordSubscription = hub.subscribe(
      mainVideo: { sampleBuffer in
        recordMediaCore.enqueueVideo(sampleBuffer, operationID: recordOperationID)
      },
      mainAudioMix: { sampleBuffer in
        recordMediaCore.enqueueMainAudio(sampleBuffer)
      },
      failureHandler: { [weak self] error in
        Task { @MainActor in
          guard let self, self.recordSubscriptionGeneration == subscriptionGeneration else {
            return
          }
          self.activeRecordStopFailure = error
          _ = await self.stopRecordServicePreservingIncompletePackage()
        }
      })
    portraitRecordSubscription = portraitHub?.subscribe(
      mainVideo: { sampleBuffer in
        recordMediaCore.enqueuePortraitVideo(sampleBuffer, operationID: recordOperationID)
      },
      mainAudioMix: { sampleBuffer in recordMediaCore.enqueuePortraitAudio(sampleBuffer) },
      failureHandler: { [weak self] error in
        Task { @MainActor in
          guard let self, self.recordSubscriptionGeneration == subscriptionGeneration else {
            return
          }
          self.activeRecordStopFailure = error
          _ = await self.stopRecordServicePreservingIncompletePackage()
        }
      })
  }

  func appendRecordInputAudio(_ sampleBuffer: CMSampleBuffer, trackID: String) {
    let recordMediaCore = recordMediaCoreSlot.current()
    if let boundaryID = recordMediaCore.receiveInputAudioSynchronously(
      sampleBuffer, trackID: trackID)
    {
      enqueueRecordMediaCommit(boundaryID)
    }
  }

  func receiveRecordMainAudio(_ sampleBuffer: CMSampleBuffer) {
    let recordMediaCore = recordMediaCoreSlot.current()
    if let boundaryID = recordMediaCore.receiveMainAudioSynchronously(sampleBuffer) {
      enqueueRecordMediaCommit(boundaryID)
    }
  }

  func beginRecordAuxiliaryOperation() -> RecordAuxiliaryLease? {
    guard let service = recordService, service.hasAcceptedFirstVideo else { return nil }
    let id = UUID()
    auxiliaryRecordServices[id] = service
    return RecordAuxiliaryLease(
      id: id,
      packageDirectory: service.packageDirectory,
      timelineMilliseconds: service.recordingTimelineMilliseconds())
  }

  func endRecordAuxiliaryOperation(_ lease: RecordAuxiliaryLease) {
    guard let service = auxiliaryRecordServices.removeValue(forKey: lease.id) else { return }
    let serviceID = ObjectIdentifier(service)
    guard !auxiliaryRecordServices.values.contains(where: { $0 === service }),
      deferredRecordFinalizers[serviceID] != nil,
      let enqueueRecordControl
    else { return }
    _ = enqueueRecordControl { [weak self] in
      guard let self,
        let deferred = self.deferredRecordFinalizers.removeValue(forKey: serviceID)
      else { return }
      self.startFinalizingRecordService(deferred)
    }
  }

  @discardableResult
  func requestRecordCut() -> Bool {
    let recordMediaCore = recordMediaCoreSlot.current()
    guard let recordService else { return false }
    let hasQueuedMainAudioFormat =
      if let recordSubscription, let recordMediaHub {
        recordMediaHub.hasMainAudioFormatDescription(recordSubscription)
      } else {
        false
      }
    let hasQueuedPortraitAudioFormat =
      if let portraitRecordSubscription, let portraitMediaHub {
        portraitMediaHub.hasMainAudioFormatDescription(portraitRecordSubscription)
      } else {
        false
      }
    let hasRequiredQueuedAudioFormats =
      (!recordService.recordsLandscapeOutput || hasQueuedMainAudioFormat)
      && (!recordService.recordsPortraitOutput || hasQueuedPortraitAudioFormat)
    guard lifecycleState == .running, activeMode?.recordsLocally == true,
      recordService.hasAcceptedFirstVideo,
      !isRecordCutCoolingDown, !isRecordCutPending,
      recordMediaCore.hasRequiredAudioFormatDescriptions(for: recordService)
        || hasRequiredQueuedAudioFormats
    else { return false }
    isRecordCutPending = true
    isRecordCutCoolingDown = true
    let subscribedHubs = [
      recordSubscription.map { (recordMediaHub, $0) },
      portraitRecordSubscription.map { (portraitMediaHub, $0) },
    ].compactMap { pair -> (ProgramOutputMediaHub, ProgramOutputMediaHub.Subscription)? in
      guard let pair, let hub = pair.0 else { return nil }
      return (hub, pair.1)
    }
    if !subscribedHubs.isEmpty {
      let barrier = WorkspaceRecordCutBarrier(arrivalCount: subscribedHubs.count) {
        recordMediaCore.enqueueCutRequest(for: recordService)
      }
      for (hub, subscription) in subscribedHubs {
        guard hub.enqueueControl(subscription, operation: barrier.arriveAndWait) else {
          barrier.cancel()
          isRecordCutPending = false
          isRecordCutCoolingDown = false
          return false
        }
      }
    } else {
      recordMediaCore.enqueueCutRequest(for: recordService)
    }
    recordEventHandler?("Cut requested")
    cutCooldownTask?.cancel()
    let waitForRecordCutCooldown = self.waitForRecordCutCooldown
    cutCooldownTask = Task { @MainActor [weak self] in
      try? await waitForRecordCutCooldown()
      guard !Task.isCancelled else { return }
      self?.isRecordCutCoolingDown = false
    }
    return true
  }

  func receiveRecordVideo(_ sampleBuffer: CMSampleBuffer) {
    let recordMediaCore = recordMediaCoreSlot.current()
    if let boundaryID = recordMediaCore.receiveVideoSynchronously(
      sampleBuffer, operationID: operationID)
    {
      enqueueRecordMediaCommit(boundaryID)
    }
  }

  func waitForRecordMediaOperations() async {
    await recordMediaCoreSlot.current().waitForPendingOperations()
  }

  func waitForRecordMediaDelivery() async {
    if let recordMediaHub, let recordSubscription {
      await waitForRecordMediaDelivery(on: recordMediaHub, subscription: recordSubscription)
    }
    if let portraitMediaHub, let portraitRecordSubscription {
      await waitForRecordMediaDelivery(
        on: portraitMediaHub,
        subscription: portraitRecordSubscription
      )
    }
    await waitForRecordMediaOperations()
  }

  private func waitForRecordMediaDelivery(
    on hub: ProgramOutputMediaHub,
    subscription: ProgramOutputMediaHub.Subscription
  ) async {
    await withCheckedContinuation { continuation in
      let accepted = hub.enqueueControl(subscription) {
        continuation.resume()
      }
      if !accepted {
        continuation.resume()
      }
    }
  }

  private func enqueueRecordMediaCommit(
    _ boundaryID: UUID, mediaCore recordMediaCore: WorkspaceRecordMediaCore? = nil
  ) {
    let recordMediaCore = recordMediaCore ?? recordMediaCoreSlot.current()
    guard recordMediaCoreSlot.current() === recordMediaCore else { return }
    guard let enqueueRecordControl else { return }
    let accepted = enqueueRecordControl { [weak self] in
      guard let self else { return }
      guard self.lifecycleState == .running, let makeRecordService = self.makeRecordService else {
        recordMediaCore.enqueueRollbackPendingCut()
        self.isRecordCutPending = false
        return
      }
      do {
        let next = try makeRecordService()
        do {
          try next.start()
        } catch {
          self.cancelReplacementRecordService(next)
          throw error
        }
        recordMediaCore.enqueueCommit(
          boundaryID: boundaryID, operationID: self.operationID, replacement: next
        ) { [weak self] result in
          guard let self, self.recordMediaCoreSlot.current() === recordMediaCore else {
            return
          }
          switch result {
          case .success(.none):
            self.cancelReplacementRecordService(next)
          case .success(.some(let commit)):
            self.recordService = commit.current
            self.isRecordCutPending = false
            self.recordEventHandler?(
              "Recording package started: \(commit.current.packageDirectory.path)")
            let deferred = recordMediaCore.deferFinalizationUntilInputAudioCallbacksDrain(
              for: commit.previous
            ) { [weak self] in
              self?.finalizePreviousRecordService(commit.previous)
            }
            if !deferred { self.finalizePreviousRecordService(commit.previous) }
          case .failure(let error):
            self.cancelReplacementRecordService(next)
            self.isRecordCutPending = false
            self.recordEventHandler?(
              "Cut failed; recording continues: \(error.localizedDescription)")
          }
        }
      } catch {
        recordMediaCore.enqueueRollbackPendingCut()
        self.isRecordCutPending = false
        self.recordEventHandler?("Cut failed; recording continues: \(error.localizedDescription)")
      }
    }
    if !accepted {
      recordMediaCore.enqueueRollbackPendingCut()
      isRecordCutPending = false
      recordEventHandler?(
        "Cut failed; recording continues: Workspace control queue rejected Cut commit")
    }
  }

  private func cancelReplacementRecordService(_ service: any SessionRecordServicing) {
    let id = ObjectIdentifier(service)
    cancellingRecordServices[id] = service
    service.cancelBeforeFirstVideo { [weak self] _ in
      self?.cancellingRecordServices[id] = nil
    }
  }

  private func finalizePreviousRecordService(_ service: any SessionRecordServicing) {
    if auxiliaryRecordServices.values.contains(where: { $0 === service }) {
      deferredRecordFinalizers[ObjectIdentifier(service)] = service
      return
    }
    startFinalizingRecordService(service)
  }

  private func startFinalizingRecordService(_ service: any SessionRecordServicing) {
    let id = ObjectIdentifier(service)
    finalizingRecordServices[id] = service
    Task { [weak self, recordFinalizerTimeout] in
      do {
        try await Task.sleep(for: recordFinalizerTimeout)
      } catch {
        return
      }
      guard let self, self.finalizingRecordServices[id] === service else { return }
      let error = ProgramOutputMediaChannelError.drainTimedOut
      if self.recordFinalizationFailure == nil { self.recordFinalizationFailure = error }
      self.recordEventHandler?(
        "Recording finalization timed out; stopping Output Session and preserving the incomplete package"
      )
      self.recordFailureHandler?(error)
      service.abandonAfterMediaDrainTimeout()
    }
    service.sealInputAudio()
    service.finishAfterCut { [weak self] result in
      guard let self else { return }
      self.finalizingRecordServices[id] = nil
      switch result {
      case .finalized:
        self.recordEventHandler?("Finalized recording: \(service.packageDirectory.path)")
      case .preservedIncomplete:
        self.recordEventHandler?("Recording preserved incomplete: \(service.packageDirectory.path)")
      case .failed(let error):
        if self.recordFinalizationFailure == nil {
          self.recordFinalizationFailure = error
        }
        self.recordEventHandler?("Recording finalize failed: \(error.localizedDescription)")
      }
    }
  }

  func installYouTubeService(
    _ service: any YouTubeOutputWorkspaceServicing,
    on hub: ProgramOutputMediaHub,
    limits: ProgramOutputMediaChannelLimits = .default
  ) {
    youtubeService = service
    youtubeSubscription = hub.subscribe(
      limits: limits,
      mainVideo: { sampleBuffer in
        service.appendMainVideo(sampleBuffer)
      },
      mainAudioMix: { sampleBuffer in
        service.appendMainAudioMix(sampleBuffer)
      },
      failureHandler: { [weak self, weak service] error in
        Task { @MainActor in
          guard let self, let service, self.youtubeService === service else { return }
          if let subscription = self.youtubeSubscription, let hub = self.currentMediaHub {
            _ = await hub.unsubscribeAndDrain(subscription)
            if self.youtubeSubscription == subscription {
              self.youtubeSubscription = nil
            }
          }
          service.failMediaDelivery(error)
        }
      })
  }

  func stopServices() async -> Result<Void, any Error> {
    async let recordResult = stopRecordService()
    async let youtubeResult = stopYouTubeService()
    let results = await (recordResult, youtubeResult)
    if case .failure = results.0 { return results.0 }
    return results.1
  }

  func stopServicesPreservingIncompleteRecording() async -> Result<Void, any Error> {
    async let recordResult = stopRecordServicePreservingIncompletePackage()
    async let youtubeResult = stopYouTubeService()
    let results = await (recordResult, youtubeResult)
    if case .failure = results.0 { return results.0 }
    return results.1
  }

  private func stopRecordServicePreservingIncompletePackage() async -> Result<Void, any Error> {
    await drainAndRemoveRecordInputAudioSubscriptions()
    recordSubscriptionGeneration = nil
    if let recordSubscription, let hub = currentMediaHub {
      _ = await hub.unsubscribeAndDrain(recordSubscription)
    }
    if let portraitRecordSubscription, let hub = portraitMediaHub {
      _ = await hub.unsubscribeAndDrain(portraitRecordSubscription)
    }
    recordSubscription = nil
    portraitRecordSubscription = nil
    recordMediaHub = nil
    let recordMediaCore = recordMediaCoreSlot.current()
    let coreDrainResult = await recordMediaCore.closeAndDrain()
    if case .failure(let error) = coreDrainResult { activeRecordStopFailure = error }
    if case .failure(.drainTimedOut) = coreDrainResult { didRecordMediaDrainTimeout = true }
    if case .success = coreDrainResult {
      cancelRecordCut()
    } else {
      cancelRecordCut(rollbackMediaCore: false)
    }
    releaseAllRecordAuxiliaryOperations()
    guard let service = recordService else {
      await waitForRecordFinalizers()
      return recordStopFailureResult()
    }
    if case .failure(.drainTimedOut) = coreDrainResult {
      service.abandonAfterMediaDrainTimeout()
      if recordService === service { recordService = nil }
      await waitForRecordFinalizers()
      return recordStopFailureResult()
    }
    isRecordFinalizing = true
    defer { isRecordFinalizing = false }
    let result = await awaitRecordFinalization(for: service) { completion in
      service.stopPreservingIncompletePackage(completionHandler: completion)
    }
    await waitForRecordFinalizers()
    if recordService === service { recordService = nil }
    return rememberActiveRecordStopResult(from: result)
  }

  func stopRecordService() async -> Result<Void, any Error> {
    await drainAndRemoveRecordInputAudioSubscriptions()
    recordSubscriptionGeneration = nil
    if let recordSubscription, let hub = currentMediaHub {
      let drainResult = await hub.unsubscribeAndDrain(recordSubscription)
      if case .failure(let error) = drainResult {
        activeRecordStopFailure = error
      }
    }
    if let portraitRecordSubscription, let hub = portraitMediaHub {
      let drainResult = await hub.unsubscribeAndDrain(portraitRecordSubscription)
      if case .failure(let error) = drainResult {
        activeRecordStopFailure = error
      }
    }
    recordSubscription = nil
    portraitRecordSubscription = nil
    recordMediaHub = nil
    let recordMediaCore = recordMediaCoreSlot.current()
    let coreDrainResult = await recordMediaCore.closeAndDrain()
    if case .failure(let error) = coreDrainResult { activeRecordStopFailure = error }
    if case .failure(.drainTimedOut) = coreDrainResult { didRecordMediaDrainTimeout = true }
    if case .success = coreDrainResult {
      cancelRecordCut()
    } else {
      cancelRecordCut(rollbackMediaCore: false)
    }
    releaseAllRecordAuxiliaryOperations()
    guard let service = recordService else {
      await waitForRecordFinalizers()
      return recordStopFailureResult()
    }
    if case .failure(.drainTimedOut) = coreDrainResult {
      service.abandonAfterMediaDrainTimeout()
      if recordService === service { recordService = nil }
      await waitForRecordFinalizers()
      return recordStopFailureResult()
    }
    isRecordFinalizing = true
    defer { isRecordFinalizing = false }
    let result = await awaitRecordFinalization(for: service) { completion in
      service.stop(completionHandler: completion)
    }
    await waitForRecordFinalizers()
    if recordService === service { recordService = nil }
    return rememberActiveRecordStopResult(from: result)
  }

  private func rememberActiveRecordStopResult(
    from result: SessionRecordFinalizationResult
  ) -> Result<Void, any Error> {
    switch result {
    case .finalized, .preservedIncomplete: return recordStopFailureResult()
    case .failed(let error):
      activeRecordStopFailure = error
      return .failure(error)
    }
  }

  private func awaitRecordFinalization(
    for service: any SessionRecordServicing,
    _ operation: (@escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void) -> Void
  ) async -> SessionRecordFinalizationResult {
    await withCheckedContinuation { continuation in
      let race = RecordFinalizationRace(continuation: continuation)
      operation { race.finish($0) }
      let timeoutTask = Task { [recordFinalizerTimeout] in
        do {
          try await Task.sleep(for: recordFinalizerTimeout)
        } catch {
          return
        }
        race.finish(.failed(ProgramOutputMediaChannelError.drainTimedOut))
        service.abandonAfterMediaDrainTimeout()
      }
      race.installTimeoutTask(timeoutTask)
    }
  }

  private func recordStopFailureResult() -> Result<Void, any Error> {
    if let activeRecordStopFailure { return .failure(activeRecordStopFailure) }
    if let recordFinalizationFailure { return .failure(recordFinalizationFailure) }
    return .success(())
  }

  private func cancelRecordCut(rollbackMediaCore: Bool = true) {
    isRecordCutPending = false
    isRecordCutCoolingDown = false
    cutCooldownTask?.cancel()
    cutCooldownTask = nil
    if rollbackMediaCore { recordMediaCoreSlot.current().rollbackPendingCut() }
  }

  private func releaseAllRecordAuxiliaryOperations() {
    auxiliaryRecordServices.removeAll()
    let services = Array(deferredRecordFinalizers.values)
    deferredRecordFinalizers.removeAll()
    services.forEach(startFinalizingRecordService)
  }

  private func waitForRecordFinalizers() async {
    let deadline = ContinuousClock.now + recordFinalizerTimeout
    while !finalizingRecordServices.isEmpty || !deferredRecordFinalizers.isEmpty
      || !cancellingRecordServices.isEmpty
    {
      if Task.isCancelled || ContinuousClock.now >= deadline {
        abandonOutstandingRecordFinalizers()
        return
      }
      do {
        try await Task.sleep(for: .milliseconds(10))
      } catch {
        abandonOutstandingRecordFinalizers()
        return
      }
    }
  }

  private func abandonOutstandingRecordFinalizers() {
    let services =
      Array(finalizingRecordServices.values)
      + Array(deferredRecordFinalizers.values)
      + Array(cancellingRecordServices.values)
    finalizingRecordServices.removeAll()
    deferredRecordFinalizers.removeAll()
    cancellingRecordServices.removeAll()
    let uniqueServices = Dictionary(
      services.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { first, _ in first }
    ).values
    for service in uniqueServices { service.abandonAfterMediaDrainTimeout() }
    guard !uniqueServices.isEmpty else { return }
    let error = ProgramOutputMediaChannelError.drainTimedOut
    if recordFinalizationFailure == nil { recordFinalizationFailure = error }
    recordEventHandler?(
      "Recording finalization timed out; incomplete packages were preserved")
  }

  func stopYouTubeService() async -> Result<Void, any Error> {
    var mediaDrainFailure: (any Error)?
    if let youtubeSubscription, let hub = currentMediaHub {
      let drainResult = await hub.unsubscribeAndDrain(youtubeSubscription)
      if case .failure(let error) = drainResult {
        mediaDrainFailure = error
        youtubeService?.failMediaDelivery(error)
      }
    }
    youtubeSubscription = nil
    guard let service = youtubeService else { return .success(()) }
    let result = await withCheckedContinuation { continuation in
      service.stop { continuation.resume(returning: $0) }
    }
    if youtubeService === service { youtubeService = nil }
    if let mediaDrainFailure { return .failure(mediaDrainFailure) }
    return result
  }

  func finishYouTubeOutputServiceProcess() async {
    guard let boundary = youtubeOutputServiceProcess else { return }
    await withCheckedContinuation { continuation in
      boundary.finish { continuation.resume() }
    }
    if youtubeOutputServiceProcess === boundary {
      youtubeOutputServiceProcess = nil
    }
  }

  func isFullyStopped() -> Bool {
    currentSession == nil && lifecycleState == .idle
  }

}

final class OutputSleepInhibitor {
  typealias Activity = NSObjectProtocol

  private let beginActivity: () -> Activity
  private let endActivity: (Activity) -> Void
  private var activity: Activity?

  init(
    beginActivity: @escaping () -> Activity = {
      ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
        reason: "LDTX is actively producing output.")
    },
    endActivity: @escaping (Activity) -> Void = { ProcessInfo.processInfo.endActivity($0) }
  ) {
    self.beginActivity = beginActivity
    self.endActivity = endActivity
  }

  func start() {
    guard activity == nil else { return }
    activity = beginActivity()
  }

  func stop() {
    guard let activity else { return }
    self.activity = nil
    endActivity(activity)
  }

  deinit {
    stop()
  }
}

private struct WorkspaceSendableSampleBuffer: @unchecked Sendable {
  var value: CMSampleBuffer
}

private func notifyRecordInputAudioSubscriptionCompletion(
  _ group: DispatchGroup,
  completionHandler: @escaping @MainActor @Sendable () -> Void
) {
  group.notify(queue: .global()) {
    Task { @MainActor in completionHandler() }
  }
}

private func resumeWhenDispatchGroupFinishes(
  _ group: DispatchGroup,
  continuation: CheckedContinuation<Void, Never>
) {
  group.notify(queue: .global()) { continuation.resume() }
}

@MainActor
private final class WorkspaceEventCompletion {
  private(set) var isFinished = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func finish() {
    guard !isFinished else { return }
    isFinished = true
    let waiters = waiters
    self.waiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  func wait() async {
    guard !isFinished else { return }
    await withCheckedContinuation { continuation in
      if isFinished {
        continuation.resume()
      } else {
        waiters.append(continuation)
      }
    }
  }
}
