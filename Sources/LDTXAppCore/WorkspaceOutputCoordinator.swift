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
  @MainActor func start(
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void)
  func acceptFirstVideo(
    _ sampleBuffer: CMSampleBuffer,
    mainAudioFormatDescription: CMAudioFormatDescription?
  ) throws
  func appendMainVideo(_ sampleBuffer: CMSampleBuffer)
  func appendMainAudioMix(_ sampleBuffer: CMSampleBuffer)
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
    case mainAudio(CMSampleBuffer)
    case inputAudio(CMSampleBuffer, trackID: String)
  }

  private struct Boundary {
    let id: UUID
    let operationID: UUID
    let previous: any SessionRecordServicing
    let firstPresentationTime: CMTime
    var latestPresentationTime: CMTime
    var samples: [Sample]
    var mainAudioFormatDescription: CMAudioFormatDescription?
    var didRequestCommit = false
  }

  struct CommitResult {
    let previous: any SessionRecordServicing
    let current: any SessionRecordServicing
  }

  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.record-media", qos: .userInitiated)
  private let drainTimeout: Duration
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
  private var pendingCommitRequestID: UUID?
  private let inputCallbackLock = NSLock()
  private var inputCallbackService: (any SessionRecordServicing)?
  private var inputCallbackCounts: [ObjectIdentifier: Int] = [:]
  private var inputCutFences: [ObjectIdentifier: CMTime] = [:]
  private var inputDrainHandlers: [ObjectIdentifier: @MainActor @Sendable () -> Void] = [:]

  init(drainTimeout: Duration = .seconds(30)) {
    self.drainTimeout = drainTimeout
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
    submissionLock.withLock { submissionState = SubmissionState(isOpen: true) }
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
      pendingCommitRequestID = nil
      submissionLock.withLock { submissionState = SubmissionState(isOpen: true) }
    }
  }

  func reset(waitForMediaQueue: Bool = true) {
    submissionLock.withLock { submissionState.isOpen = false }
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
      pendingCommitRequestID = nil
    }
    if waitForMediaQueue {
      queue.sync(execute: resetState)
    } else {
      queue.async(execute: resetState)
    }
  }

  func requestCut(operationID: UUID) -> Bool {
    queue.sync {
      guard let activeService, activeService.hasAcceptedFirstVideo, !isCutPending else {
        return false
      }
      isCutPending = true
      return true
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

  func commit(
    boundaryID: UUID,
    operationID: UUID,
    replacement: any SessionRecordServicing
  ) throws -> CommitResult? {
    try queue.sync {
      guard let boundary, boundary.id == boundaryID else { return nil }
      guard boundary.operationID == operationID, activeService === boundary.previous else {
        rollbackBoundary()
        return nil
      }
      guard case .video(let firstVideo) = boundary.samples.first else {
        rollbackBoundary()
        throw WorkspaceRecordMediaCoreError.firstVideoMissing
      }
      guard let mainAudioFormatDescription = boundary.mainAudioFormatDescription else {
        rollbackBoundary()
        throw WorkspaceRecordMediaCoreError.mainAudioFormatMissing
      }
      do {
        try replacement.acceptFirstVideo(
          firstVideo,
          mainAudioFormatDescription: mainAudioFormatDescription)
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
      for sample in boundary.samples.dropFirst() { deliver(sample, to: replacement) }
      return CommitResult(previous: boundary.previous, current: replacement)
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
      mainAudioFormatDescription: latestMainAudioFormatDescription)
    self.boundary = boundary
    requestCommitIfReady(boundary.id)
  }

  private func receiveMainAudio(_ sampleBuffer: CMSampleBuffer) {
    if let formatDescription = sampleBuffer.formatDescription {
      latestMainAudioFormatDescription = formatDescription
    }
    if boundary != nil {
      appendToBoundary(.mainAudio(sampleBuffer))
    } else {
      activeService?.appendMainAudioMix(sampleBuffer)
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
    if case .mainAudio(let buffer) = sample, let format = buffer.formatDescription {
      boundary.mainAudioFormatDescription = format
    }
    if presentationTime.isNumeric,
      !boundary.latestPresentationTime.isNumeric
        || CMTimeCompare(presentationTime, boundary.latestPresentationTime) > 0
    {
      boundary.latestPresentationTime = presentationTime
    }
    self.boundary = boundary
    requestCommitIfReady(boundary.id)
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
    guard var boundary, boundary.id == boundaryID, !boundary.didRequestCommit,
      boundary.mainAudioFormatDescription != nil
    else { return }
    boundary.didRequestCommit = true
    self.boundary = boundary
    pendingCommitRequestID = boundaryID
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
        let failureHandler = self.failureHandler
        Task { @MainActor in
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
    case .mainAudio(let buffer): service.appendMainAudioMix(buffer)
    case .inputAudio(let buffer, let trackID):
      service.appendInputAudio(buffer, trackID: trackID)
    }
  }

  private func presentationTime(of sample: Sample) -> CMTime {
    switch sample {
    case .video(let buffer), .mainAudio(let buffer), .inputAudio(let buffer, _):
      buffer.presentationTimeStamp
    }
  }

  private static func isAudio(_ sample: Sample) -> Bool {
    switch sample {
    case .video: false
    case .mainAudio, .inputAudio: true
    }
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
    let accepted = queue.enqueue { completion in
      { _, logger in
        Task { @MainActor in
          defer {
            completionState.finish()
            completion()
          }
          await operation(logger)
        }
      }
    }
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
    await withCheckedContinuation { continuation in
      queue.stop { continuation.resume() }
    }
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
  var currentSession: ActiveProgramOutputSession?
  var currentMediaHub: ProgramOutputMediaHub?
  var recordService: (any SessionRecordServicing)?
  var youtubeService: (any YouTubeOutputWorkspaceServicing)?
  var sharedH264Service: ProgramOutputSharedH264Service?
  @ObservationIgnored private var recordSubscription: ProgramOutputMediaHub.Subscription?
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
  @ObservationIgnored private var enqueueRecordControl:
    ((@escaping @MainActor @Sendable () -> Void) -> Bool)?
  @ObservationIgnored nonisolated private let recordMediaCoreSlot: WorkspaceRecordMediaCoreSlot
  @ObservationIgnored private let recordMediaDrainTimeout: Duration
  @ObservationIgnored private let waitForRecordCutCooldown: @Sendable () async throws -> Void
  @ObservationIgnored private let copyRecordInputAudioSample:
    @Sendable (CMSampleBuffer) throws -> ProgramOwnedPCMSampleBuffer

  init(
    sleepInhibitor: OutputSleepInhibitor = OutputSleepInhibitor(),
    recordMediaDrainTimeout: Duration = .seconds(30),
    copyRecordInputAudioSample:
      @escaping @Sendable (CMSampleBuffer) throws ->
      ProgramOwnedPCMSampleBuffer = { try ProgramOwnedPCMSampleBuffer(copying: $0) },
    waitForRecordCutCooldown: @escaping @Sendable () async throws -> Void = {
      try await ContinuousClock().sleep(for: .seconds(2))
    }
  ) {
    self.sleepInhibitor = sleepInhibitor
    let recordMediaCore = WorkspaceRecordMediaCore(drainTimeout: recordMediaDrainTimeout)
    recordMediaCoreSlot = WorkspaceRecordMediaCoreSlot(recordMediaCore)
    self.recordMediaDrainTimeout = recordMediaDrainTimeout
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
    recordService = nil
    youtubeService = nil
    sharedH264Service = nil
    recordSubscription = nil
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
    enqueueRecordControl = nil
    recordMediaCore.reset(waitForMediaQueue: waitForRecordMediaQueue)
    if !waitForRecordMediaQueue {
      let replacement = WorkspaceRecordMediaCore(drainTimeout: recordMediaDrainTimeout)
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
    makeNext: @escaping () throws -> any SessionRecordServicing,
    enqueueControl: @escaping (@escaping @MainActor @Sendable () -> Void) -> Bool,
    eventHandler: @escaping @MainActor @Sendable (String) -> Void
  ) {
    let recordMediaCore = recordMediaCoreSlot.current()
    recordService = service
    recordMediaCore.install(service)
    makeRecordService = makeNext
    enqueueRecordControl = enqueueControl
    recordEventHandler = eventHandler
    let recordOperationID = operationID
    let subscriptionGeneration = UUID()
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
    guard lifecycleState == .running, activeMode?.recordsLocally == true,
      recordService != nil,
      !isRecordCutCoolingDown, !isRecordCutPending
    else { return false }
    let recordMediaCore = recordMediaCoreSlot.current()
    recordMediaCore.synchronizeActiveIfNeeded(recordService)
    guard recordMediaCore.requestCut(operationID: operationID) else { return false }
    isRecordCutPending = true
    isRecordCutCoolingDown = true
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

  private func enqueueRecordMediaCommit(
    _ boundaryID: UUID, mediaCore recordMediaCore: WorkspaceRecordMediaCore? = nil
  ) {
    let recordMediaCore = recordMediaCore ?? recordMediaCoreSlot.current()
    guard recordMediaCoreSlot.current() === recordMediaCore else { return }
    guard let enqueueRecordControl else { return }
    let accepted = enqueueRecordControl { [weak self] in
      guard let self else { return }
      guard self.lifecycleState == .running, let makeRecordService = self.makeRecordService else {
        recordMediaCore.rollbackPendingCut()
        self.isRecordCutPending = false
        return
      }
      var replacement: (any SessionRecordServicing)?
      do {
        let next = try makeRecordService()
        replacement = next
        var startResult: Result<Void, any Error>?
        next.start { startResult = $0 }
        if case .failure(let error) = startResult { throw error }
        guard
          let result = try recordMediaCore.commit(
            boundaryID: boundaryID,
            operationID: self.operationID,
            replacement: next)
        else {
          self.cancelReplacementRecordService(next)
          return
        }
        self.recordService = result.current
        self.isRecordCutPending = false
        self.recordEventHandler?(
          "Recording package started: \(result.current.packageDirectory.path)")
        let deferred = recordMediaCore.deferFinalizationUntilInputAudioCallbacksDrain(
          for: result.previous
        ) { [weak self] in
          self?.finalizePreviousRecordService(result.previous)
        }
        if !deferred { self.finalizePreviousRecordService(result.previous) }
      } catch {
        if let replacement { self.cancelReplacementRecordService(replacement) }
        recordMediaCore.rollbackPendingCut()
        self.isRecordCutPending = false
        self.recordEventHandler?("Cut failed; recording continues: \(error.localizedDescription)")
      }
    }
    if !accepted {
      recordMediaCore.rollbackPendingCut()
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
    recordSubscription = nil
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
    let result = await withCheckedContinuation { continuation in
      service.stopPreservingIncompletePackage { continuation.resume(returning: $0) }
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
    recordSubscription = nil
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
    let result = await withCheckedContinuation { continuation in
      service.stop { continuation.resume(returning: $0) }
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
    while !finalizingRecordServices.isEmpty || !deferredRecordFinalizers.isEmpty
      || !cancellingRecordServices.isEmpty
    {
      try? await Task.sleep(for: .milliseconds(10))
    }
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
