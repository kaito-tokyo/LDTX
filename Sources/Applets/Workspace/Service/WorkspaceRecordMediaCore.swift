// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import Foundation
import LDTXProgramRuntime

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

final class WorkspaceRecordMediaCore: @unchecked Sendable {
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

  private struct Boundary: @unchecked Sendable {
    let id: UUID
    let operationID: UUID
    let previous: any SessionRecordServicing
    var firstPresentationTime: CMTime
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
  private var audioFormatReadinessChanged: @MainActor @Sendable () -> Void = {}
  private var activeService: (any SessionRecordServicing)?
  private var boundary: Boundary?
  private var replacementPreparation: ReplacementPreparation?
  private let preparationLock = NSLock()
  private var admittedPreparation: ReplacementPreparation?

  private final class ReplacementPreparation: @unchecked Sendable {
    let lock = NSLock()
    private var finished = false
    var timeout: Task<Void, Never>?
    let replacement: any SessionRecordServicing
    let completion: @MainActor @Sendable (Result<CommitResult?, Error>) -> Void

    init(
      replacement: any SessionRecordServicing,
      completion: @escaping @MainActor @Sendable (Result<CommitResult?, Error>) -> Void
    ) {
      self.replacement = replacement
      self.completion = completion
    }
    var isCancelled: Bool { lock.withLock { finished } }
    func claimCompletion() -> Bool {
      lock.withLock {
        guard !finished else { return false }
        finished = true
        return true
      }
    }
    func abandon() {
      guard claimCompletion() else { return }
      Task { @MainActor in
        replacement.abandonAfterMediaDrainTimeout()
        completion(.failure(WorkspaceRecordingPreparationAbandoned()))
      }
    }
  }
  private var isCutPending = false
  private var pendingCutAudio: [Sample] = []
  private var pendingCutAudioByteCount = 0
  private var deliveredAudioEnd = CMTime.invalid
  private var earliestCutTime = CMTime.invalid
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
    cutStateChanged: @escaping @MainActor @Sendable (Bool) -> Void,
    audioFormatReadinessChanged: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    queue.sync {
      self.commitRequest = commitRequest
      self.eventHandler = eventHandler
      self.failureHandler = failureHandler
      self.cutStateChanged = cutStateChanged
      self.audioFormatReadinessChanged = audioFormatReadinessChanged
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
      deliveredAudioEnd = .invalid
      earliestCutTime = .invalid
      boundary = nil
      isCutPending = false
      pendingCutAudio = []
      pendingCutAudioByteCount = 0
      pendingCutAudio = []
      pendingCutAudioByteCount = 0
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
      pendingCutAudio = []
      pendingCutAudioByteCount = 0
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
        pendingCutAudio = []
        pendingCutAudioByteCount = 0
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
      earliestCutTime = deliveredAudioEnd
      pendingCutAudio = []
      pendingCutAudioByteCount = 0
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

  /// First-video preparation may block in a writer. It must never occupy the
  /// recording queue, which owns rollback and continues buffering both canvases.
  func enqueueCommit(
    boundaryID: UUID,
    operationID: UUID,
    replacement: any SessionRecordServicing,
    preparationTimeout: Duration = .seconds(10),
    completionHandler: @escaping @MainActor @Sendable (Result<CommitResult?, Error>) -> Void
  ) {
    let preparation = ReplacementPreparation(
      replacement: replacement, completion: completionHandler)
    let admitted = preparationLock.withLock {
      guard admittedPreparation == nil else { return false }
      admittedPreparation = preparation
      return true
    }
    guard admitted else {
      Task { @MainActor in completionHandler(.success(nil)) }
      return
    }
    // Start the deadline before entering the recording queue: it may already be
    // stalled in an active writer or in rollback delivery.
    let timeout = Task { [self] in
      do { try await Task.sleep(for: preparationTimeout) } catch { return }
      preparation.abandon()
      queue.async { [self] in
        if self.boundary?.id == boundaryID { rollbackBoundary() }
        clearAdmittedPreparation(preparation)
      }
    }
    queue.async { [self] in
      guard !preparation.isCancelled else {
        timeout.cancel()
        clearAdmittedPreparation(preparation)
        return
      }
      guard let boundary, boundary.id == boundaryID,
        boundary.operationID == operationID, activeService === boundary.previous,
        replacementPreparation == nil
      else {
        timeout.cancel()
        clearAdmittedPreparation(preparation)
        if preparation.claimCompletion() {
          Task { @MainActor in completionHandler(.success(nil)) }
        }
        return
      }
      replacementPreparation = preparation
      preparation.timeout = timeout
      // Each attempt owns an executor: a stalled previous attempt cannot hold up
      // a later cut. Its closure retains the abandoned writer until it returns.
      DispatchQueue(label: "tokyo.kaito.ldtx.record-replacement").async { [self] in
        let result = Result { try Self.prepareReplacement(boundary, preparation: preparation) }
        queue.async { [self] in
          guard replacementPreparation === preparation else { return }
          replacementPreparation = nil
          timeout.cancel()
          clearAdmittedPreparation(preparation)
          guard preparation.claimCompletion() else {
            rollbackBoundary()
            return
          }
          switch result {
          case .failure(let error):
            Task { @MainActor in completionHandler(.failure(error)) }
            rollbackBoundary()
          case .success:
            guard let currentBoundary = self.boundary,
              currentBoundary.id == boundaryID, activeService === boundary.previous
            else {
              Task { @MainActor in completionHandler(.success(nil)) }
              return
            }
            commitPreparedReplacement(currentBoundary, replacement: replacement) { result in
              // Ownership is settled before buffered delivery, which can itself
              // stall in the old writer. Finalization has its own bounded fence.
              Task { @MainActor in completionHandler(.success(result)) }
            }
          }
        }
      }
    }
  }

  private func clearAdmittedPreparation(_ preparation: ReplacementPreparation) {
    preparationLock.withLock {
      if admittedPreparation === preparation { admittedPreparation = nil }
    }
  }

  private static func prepareReplacement(
    _ boundary: Boundary, preparation: ReplacementPreparation
  ) throws {
    let replacement = preparation.replacement
    var firstVideos: [(CMSampleBuffer, () throws -> Void)] = []
    if boundary.previous.recordsLandscapeOutput {
      guard let video = boundary.landscapeFirstVideo,
        let audioFormat = boundary.mainAudioFormatDescription
      else { throw WorkspaceRecordMediaCoreError.firstVideoMissing }
      firstVideos.append(
        (
          video,
          {
            try replacement.acceptFirstVideo(video, mainAudioFormatDescription: audioFormat)
          }
        ))
    }
    if boundary.previous.recordsPortraitOutput {
      guard let video = boundary.portraitFirstVideo,
        let audioFormat = boundary.portraitAudioFormatDescription
      else { throw WorkspaceRecordMediaCoreError.firstVideoMissing }
      firstVideos.append(
        (
          video,
          {
            try replacement.acceptFirstPortraitVideo(
              video, mainAudioFormatDescription: audioFormat)
          }
        ))
    }
    for (_, accept) in firstVideos.sorted(by: {
      CMTimeCompare($0.0.presentationTimeStamp, $1.0.presentationTimeStamp) < 0
    }) {
      guard !preparation.isCancelled else { return }
      try accept()
    }
  }

  private func commitPreparedReplacement(
    _ boundary: Boundary, replacement: any SessionRecordServicing,
    didCommit: (CommitResult) -> Void
  ) {
    activeService = replacement
    inputCallbackLock.withLock {
      inputCallbackService = replacement
      inputCutFences[ObjectIdentifier(boundary.previous)] = boundary.firstPresentationTime
    }
    self.boundary = nil
    isCutPending = false
    didCommit(CommitResult(previous: boundary.previous, current: replacement))
    for sample in boundary.samples {
      switch sample {
      case .mainAudio(let buffer):
        deliverAudio(
          buffer, at: boundary.landscapeFirstVideo?.presentationTimeStamp,
          previous: boundary.previous, replacement: replacement
        ) { service, sample in
          service.appendMainAudioMix(sample)
        }
      case .portraitAudio(let buffer):
        deliverAudio(
          buffer, at: boundary.portraitFirstVideo?.presentationTimeStamp,
          previous: boundary.previous, replacement: replacement
        ) { service, sample in
          service.appendPortraitAudioMix(sample)
        }
      case .inputAudio(let buffer, let trackID):
        deliverAudio(
          buffer, at: boundary.firstPresentationTime,
          previous: boundary.previous, replacement: replacement
        ) { service, sample in
          service.appendInputAudio(sample, trackID: trackID)
        }
      case .video(let buffer) where buffer === boundary.landscapeFirstVideo:
        continue
      case .portraitVideo(let buffer) where buffer === boundary.portraitFirstVideo:
        continue
      default:
        deliver(
          sample,
          to: Self.precedesCanvasStart(sample, boundary: boundary)
            ? boundary.previous : replacement)
      }
    }
  }

  /// PCM buffers can straddle a video boundary. Split by audio sample index so
  /// neither package loses the portion on its side of the cut.
  private func deliverAudio(
    _ buffer: CMSampleBuffer, at boundary: CMTime?,
    previous: any SessionRecordServicing, replacement: any SessionRecordServicing,
    append: (any SessionRecordServicing, CMSampleBuffer) -> Void
  ) {
    noteDeliveredAudio(buffer)
    guard let boundary, boundary.isNumeric, buffer.presentationTimeStamp.isNumeric,
      let format = buffer.formatDescription,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
      asbd.mSampleRate > 0, asbd.mSampleRate <= Double(Int32.max)
    else {
      append(replacement, buffer)
      return
    }
    let frames = CMTimeConvertScale(
      CMTimeSubtract(boundary, buffer.presentationTimeStamp),
      timescale: Int32(asbd.mSampleRate), method: .roundTowardPositiveInfinity
    ).value
    let count = CMSampleBufferGetNumSamples(buffer)
    if frames <= 0 {
      append(replacement, buffer)
      return
    }
    if frames >= count {
      append(previous, buffer)
      return
    }
    // Our PCM producers intentionally omit per-sample sizes. CoreMedia's range
    // copy requires them, so supply a sized view over the same immutable data.
    var sized: CMSampleBuffer?
    var timing = CMSampleTimingInfo()
    let timingStatus = CMSampleBufferGetSampleTimingInfo(buffer, at: 0, timingInfoOut: &timing)
    var frameBytes = Int(asbd.mBytesPerFrame)
    let viewStatus =
      timingStatus == noErr
      ? CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: buffer.dataBuffer,
        formatDescription: format, sampleCount: count,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &frameBytes, sampleBufferOut: &sized)
      : timingStatus
    var prefix: CMSampleBuffer?
    var suffix: CMSampleBuffer?
    let firstStatus =
      sized.map {
        CMSampleBufferCopySampleBufferForRange(
          allocator: kCFAllocatorDefault,
          sampleBuffer: $0, sampleRange: CFRange(location: 0, length: Int(frames)),
          sampleBufferOut: &prefix)
      } ?? viewStatus
    let secondStatus =
      sized.map {
        CMSampleBufferCopySampleBufferForRange(
          allocator: kCFAllocatorDefault,
          sampleBuffer: $0,
          sampleRange: CFRange(location: Int(frames), length: count - Int(frames)),
          sampleBufferOut: &suffix)
      } ?? viewStatus
    guard firstStatus == noErr, secondStatus == noErr, let prefix, let suffix else {
      let error = NSError(
        domain: NSOSStatusErrorDomain,
        code: Int(firstStatus != noErr ? firstStatus : secondStatus))
      Task { @MainActor [failureHandler] in failureHandler(error) }
      return
    }
    append(previous, prefix)
    append(replacement, suffix)
  }

  private static func precedesCanvasStart(_ sample: Sample, boundary: Boundary) -> Bool {
    switch sample {
    case .video(let buffer), .mainAudio(let buffer):
      return precedes(buffer, boundary.landscapeFirstVideo)
    case .portraitVideo(let buffer), .portraitAudio(let buffer):
      return precedes(buffer, boundary.portraitFirstVideo)
    case .inputAudio(let buffer, _):
      return precedes(buffer, boundary.firstPresentationTime)
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

  private static func precedes(_ sampleBuffer: CMSampleBuffer, _ presentationTime: CMTime) -> Bool {
    let samplePresentationTime = sampleBuffer.presentationTimeStamp
    return samplePresentationTime.isNumeric && presentationTime.isNumeric
      && CMTimeCompare(samplePresentationTime, presentationTime) < 0
  }

  func enqueueRollbackPendingCut(
    completion: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    // Cancellation cannot depend on admission to a potentially stalled executor.
    preparationLock.withLock { admittedPreparation }?.abandon()
    queue.async { [self] in
      rollbackBoundary()
      Task { @MainActor in completion() }
    }
  }

  func waitForPendingOperations() async {
    await withCheckedContinuation { continuation in
      queue.async {
        Task { @MainActor in continuation.resume() }
      }
    }
  }

  private func receiveVideo(_ sampleBuffer: CMSampleBuffer, operationID: UUID) {
    if let activeService, !activeService.recordsLandscapeOutput {
      activeService.appendMainVideo(sampleBuffer)
      return
    }
    if boundary != nil {
      appendToBoundary(.video(sampleBuffer))
      return
    }
    guard isCutPending, Self.isSyncVideoSample(sampleBuffer),
      !earliestCutTime.isNumeric
        || CMTimeCompare(sampleBuffer.presentationTimeStamp, earliestCutTime) >= 0,
      let activeService
    else {
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
      bufferedByteCount: pendingCutAudioByteCount + Self.byteCount(of: sampleBuffer),
      mainAudioFormatDescription: latestMainAudioFormatDescription,
      portraitAudioFormatDescription: latestPortraitAudioFormatDescription,
      landscapeFirstVideo: sampleBuffer,
      portraitFirstVideo: nil)
    self.boundary = boundary
    self.boundary?.samples.insert(contentsOf: pendingCutAudio, at: 0)
    pendingCutAudio = []
    pendingCutAudioByteCount = 0
    guard boundary.bufferedByteCount <= boundaryByteLimit else {
      failBoundaryForByteLimit()
      return
    }
    requestCommitIfReady(boundary.id)
  }

  private func receivePortraitVideo(_ sampleBuffer: CMSampleBuffer, operationID: UUID) {
    if let activeService, !activeService.recordsPortraitOutput {
      activeService.appendPortraitVideo(sampleBuffer)
      return
    }
    if boundary != nil {
      appendToBoundary(.portraitVideo(sampleBuffer))
      return
    }
    guard isCutPending, Self.isSyncVideoSample(sampleBuffer),
      !earliestCutTime.isNumeric
        || CMTimeCompare(sampleBuffer.presentationTimeStamp, earliestCutTime) >= 0,
      let activeService
    else {
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
      bufferedByteCount: pendingCutAudioByteCount + Self.byteCount(of: sampleBuffer),
      mainAudioFormatDescription: latestMainAudioFormatDescription,
      portraitAudioFormatDescription: latestPortraitAudioFormatDescription,
      landscapeFirstVideo: nil,
      portraitFirstVideo: sampleBuffer)
    self.boundary = boundary
    self.boundary?.samples.insert(contentsOf: pendingCutAudio, at: 0)
    pendingCutAudio = []
    pendingCutAudioByteCount = 0
    guard boundary.bufferedByteCount <= boundaryByteLimit else {
      failBoundaryForByteLimit()
      return
    }
    requestCommitIfReady(boundary.id)
  }

  private func receiveMainAudio(_ sampleBuffer: CMSampleBuffer) {
    if let formatDescription = sampleBuffer.formatDescription {
      latestMainAudioFormatDescription = formatDescription
      let changed = mainAudioFormatLock.withLock {
        let changed = !hasMainAudioFormat
        hasMainAudioFormat = true
        return changed
      }
      if changed {
        Task { @MainActor [audioFormatReadinessChanged] in audioFormatReadinessChanged() }
      }
    }
    if boundary != nil {
      appendToBoundary(.mainAudio(sampleBuffer))
    } else if isCutPending {
      appendPendingCutAudio(.mainAudio(sampleBuffer))
    } else {
      noteDeliveredAudio(sampleBuffer)
      activeService?.appendMainAudioMix(sampleBuffer)
    }
  }

  private func receivePortraitAudio(_ sampleBuffer: CMSampleBuffer) {
    if let formatDescription = sampleBuffer.formatDescription {
      latestPortraitAudioFormatDescription = formatDescription
      let changed = portraitAudioFormatLock.withLock {
        let changed = !hasPortraitAudioFormat
        hasPortraitAudioFormat = true
        return changed
      }
      if changed {
        Task { @MainActor [audioFormatReadinessChanged] in audioFormatReadinessChanged() }
      }
    }
    if boundary != nil {
      appendToBoundary(.portraitAudio(sampleBuffer))
    } else if isCutPending {
      appendPendingCutAudio(.portraitAudio(sampleBuffer))
    } else {
      noteDeliveredAudio(sampleBuffer)
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
        if let activeService {
          deliverAudio(
            sampleBuffer, at: fence, previous: callback.service,
            replacement: activeService
          ) { service, sample in
            service.appendInputAudio(sample, trackID: trackID)
          }
        }
        return
      }
    }
    if boundary != nil {
      appendToBoundary(.inputAudio(sampleBuffer, trackID: trackID))
    } else if isCutPending {
      appendPendingCutAudio(.inputAudio(sampleBuffer, trackID: trackID))
    } else {
      noteDeliveredAudio(sampleBuffer)
      activeService?.appendInputAudio(sampleBuffer, trackID: trackID)
    }
  }

  private func appendToBoundary(_ sample: Sample) {
    guard var boundary else { return }
    switch sample {
    case .video where !boundary.previous.recordsLandscapeOutput,
      .portraitVideo where !boundary.previous.recordsPortraitOutput:
      return
    default:
      break
    }
    let presentationTime = presentationTime(of: sample)
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
    var acceptedFirstCanvasVideo = false
    if case .video(let buffer) = sample, boundary.landscapeFirstVideo == nil,
      Self.isSyncVideoSample(buffer),
      !earliestCutTime.isNumeric
        || CMTimeCompare(buffer.presentationTimeStamp, earliestCutTime) >= 0
    {
      boundary.landscapeFirstVideo = buffer
      acceptedFirstCanvasVideo = true
    }
    if case .portraitVideo(let buffer) = sample, boundary.portraitFirstVideo == nil,
      Self.isSyncVideoSample(buffer),
      !earliestCutTime.isNumeric
        || CMTimeCompare(buffer.presentationTimeStamp, earliestCutTime) >= 0
    {
      boundary.portraitFirstVideo = buffer
      acceptedFirstCanvasVideo = true
    }
    if acceptedFirstCanvasVideo, presentationTime.isNumeric,
      !boundary.firstPresentationTime.isNumeric
        || CMTimeCompare(presentationTime, boundary.firstPresentationTime) < 0
    {
      boundary.firstPresentationTime = presentationTime
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

  private func appendPendingCutAudio(_ sample: Sample) {
    pendingCutAudio.append(sample)
    let byteCount = Self.byteCount(of: sampleBuffer(of: sample))
    let (total, overflow) = pendingCutAudioByteCount.addingReportingOverflow(byteCount)
    pendingCutAudioByteCount = overflow ? Int.max : total
    guard pendingCutAudioByteCount <= boundaryByteLimit else {
      rollbackBoundary()
      Task { @MainActor [eventHandler] in
        eventHandler("Cut failed; recording continues: Cut commit exceeded the boundary byte limit")
      }
      return
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
    if let preparation = replacementPreparation {
      replacementPreparation = nil
      preparation.abandon()
      preparation.timeout?.cancel()
      clearAdmittedPreparation(preparation)
    }
    guard let boundary else {
      if let activeService {
        for sample in pendingCutAudio { deliver(sample, to: activeService) }
      }
      pendingCutAudio = []
      pendingCutAudioByteCount = 0
      isCutPending = false
      let cutStateChanged = self.cutStateChanged
      Task { @MainActor in cutStateChanged(false) }
      return
    }
    self.boundary = nil
    isCutPending = false
    pendingCommitRequestID = nil
    pendingCutAudio = []
    pendingCutAudioByteCount = 0
    let cutStateChanged = self.cutStateChanged
    Task { @MainActor in cutStateChanged(false) }
    if activeService === boundary.previous {
      for sample in boundary.samples { deliver(sample, to: boundary.previous) }
    }
  }

  private func noteDeliveredAudio(_ sample: CMSampleBuffer) {
    let end = CMTimeAdd(sample.presentationTimeStamp, sample.duration)
    if end.isNumeric, !deliveredAudioEnd.isNumeric || CMTimeCompare(end, deliveredAudioEnd) > 0 {
      deliveredAudioEnd = end
    }
  }

  private func deliver(_ sample: Sample, to service: any SessionRecordServicing) {
    switch sample {
    case .mainAudio(let buffer), .portraitAudio(let buffer), .inputAudio(let buffer, _):
      noteDeliveredAudio(buffer)
    default: break
    }
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

final class WorkspaceRecordCutBarrier: @unchecked Sendable {
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

private struct WorkspaceSendableSampleBuffer: @unchecked Sendable {
  var value: CMSampleBuffer
}

final class RecordFinalizationRace: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<SessionRecordFinalizationResult, Never>?
  private var timeoutTask: Task<Void, Never>?

  init(continuation: CheckedContinuation<SessionRecordFinalizationResult, Never>) {
    self.continuation = continuation
  }

  var isFinished: Bool { lock.withLock { continuation == nil } }

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

/// Preparation may still be executing. Cleanup must not wait on or delete its writer.
struct WorkspaceRecordingPreparationAbandoned: LocalizedError {
  var errorDescription: String? {
    "Recording cut preparation was interrupted or exceeded its deadline."
  }
}
