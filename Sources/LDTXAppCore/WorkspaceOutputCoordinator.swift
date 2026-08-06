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

@MainActor
protocol SessionRecordServicing: AnyObject {
  var packageDirectory: URL { get }
  var hasAcceptedFirstVideo: Bool { get }
  func start(
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void)
  func acceptFirstVideo(
    _ sampleBuffer: CMSampleBuffer,
    mainAudioFormatDescription: CMAudioFormatDescription?
  ) throws
  func appendMainVideo(_ sampleBuffer: CMSampleBuffer)
  func appendMainAudioMix(_ sampleBuffer: CMSampleBuffer)
  func appendInputAudio(_ sampleBuffer: CMSampleBuffer, trackID: String)
  func sealInputAudio()
  func stop(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void)
  func finishAfterCut(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void)
  func stopPreservingIncompletePackage(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void)
  func cancelBeforeFirstVideo(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void)
  func recordingTimelineMilliseconds() -> UInt64?
  func recordOutputStarted()
}

extension SessionRecordService: SessionRecordServicing {}

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
  private enum RecordBoundarySample {
    case video(CMSampleBuffer)
    case mainAudio(CMSampleBuffer)
    case inputAudio(CMSampleBuffer, trackID: String)
  }

  private struct RecordCutBoundary {
    let id: UUID
    let operationID: UUID
    let previous: any SessionRecordServicing
    let firstPresentationTime: CMTime
    var latestPresentationTime: CMTime
    var samples: [RecordBoundarySample]
    var mainAudioFormatDescription: CMAudioFormatDescription?
    var isCommitEnqueued: Bool
  }

  private struct RecordCutAudioFence {
    let id: UUID
    let previous: any SessionRecordServicing
    let firstPresentationTime: CMTime
  }

  struct RecordAuxiliaryLease {
    let id: UUID
    let packageDirectory: URL
    let timelineMilliseconds: UInt64?
  }
  @ObservationIgnored private let sleepInhibitor: OutputSleepInhibitor
  var currentSession: ActiveProgramOutputSession?
  var currentMediaHub: ProgramOutputMediaHub?
  var recordService: (any SessionRecordServicing)?
  var youtubeService: YouTubeOutputWorkspaceService?
  var sharedH264Service: ProgramOutputSharedH264Service?
  @ObservationIgnored private var recordSubscription: ProgramOutputMediaHub.Subscription?
  @ObservationIgnored private var recordInputAudioSubscriptions:
    [WorkspaceCaptureSessionCoordinator.AudioSubscription] = []
  @ObservationIgnored private weak var recordCaptureSessionCoordinator:
    WorkspaceCaptureSessionCoordinator?
  @ObservationIgnored private let recordAudioDeliveries = RecordAudioDeliveryTracker()
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
  @ObservationIgnored private var recordFinalizationFailure: (any Error)?
  @ObservationIgnored private var cutCooldownTask: Task<Void, Never>?
  @ObservationIgnored private var isRecordCutPending = false
  @ObservationIgnored private var recordEventHandler: (@MainActor @Sendable (String) -> Void)?
  @ObservationIgnored private var enqueueRecordControl:
    ((@escaping @MainActor @Sendable () -> Void) -> Bool)?
  @ObservationIgnored private var recordCutBoundary: RecordCutBoundary?
  @ObservationIgnored private var latestMainAudioFormatDescription: CMAudioFormatDescription?
  @ObservationIgnored private var recordCutAudioFences: [UUID: RecordCutAudioFence] = [:]
  @ObservationIgnored private let waitForRecordCutCooldown: @Sendable () async throws -> Void

  init(
    sleepInhibitor: OutputSleepInhibitor = OutputSleepInhibitor(),
    waitForRecordCutCooldown: @escaping @Sendable () async throws -> Void = {
      try await ContinuousClock().sleep(for: .seconds(2))
    }
  ) {
    self.sleepInhibitor = sleepInhibitor
    self.waitForRecordCutCooldown = waitForRecordCutCooldown
  }

  func beginStarting() -> UUID {
    let operationID = UUID()
    self.operationID = operationID
    lifecycleState = .starting
    return operationID
  }

  func invalidateOperations(for state: OutputSessionControlState) -> UUID {
    if state == .stopping || state == .pausing {
      cancelRecordCut()
    }
    let operationID = UUID()
    self.operationID = operationID
    lifecycleState = state
    return operationID
  }

  func resetSession() {
    sleepInhibitor.stop()
    currentSession = nil
    currentMediaHub = nil
    recordService = nil
    youtubeService = nil
    sharedH264Service = nil
    recordSubscription = nil
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
    recordFinalizationFailure = nil
    cutCooldownTask?.cancel()
    cutCooldownTask = nil
    isRecordCutPending = false
    recordEventHandler = nil
    enqueueRecordControl = nil
    recordCutBoundary = nil
    latestMainAudioFormatDescription = nil
    recordCutAudioFences = [:]
  }

  func installRecordInputAudioSubscriptions(
    tracks: [SessionRecordAudioTrack],
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    failureHandler: @escaping @MainActor @Sendable (Error) -> Void,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
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
          let sample: ProgramOwnedPCMSampleBuffer
          do {
            sample = try ProgramOwnedPCMSampleBuffer(copying: sampleBuffer)
          } catch {
            Task { @MainActor in failureHandler(error) }
            return
          }
          let deliveries = self.recordAudioDeliveries
          deliveries.begin()
          dispatchToWorkspaceOutputMainActor { [weak self, deliveries] in
            defer { deliveries.end() }
            self?.appendRecordInputAudio(sample.value, trackID: track.trackID)
          }
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
    await recordAudioDeliveries.waitForDrain()
  }

  func installRecordService(
    _ service: any SessionRecordServicing,
    on hub: ProgramOutputMediaHub,
    makeNext: @escaping () throws -> any SessionRecordServicing,
    enqueueControl: @escaping (@escaping @MainActor @Sendable () -> Void) -> Bool,
    eventHandler: @escaping @MainActor @Sendable (String) -> Void
  ) {
    recordService = service
    makeRecordService = makeNext
    enqueueRecordControl = enqueueControl
    recordEventHandler = eventHandler
    recordSubscription = hub.subscribe(
      mainVideo: { [weak self] sampleBuffer in
        let sample = WorkspaceSendableSampleBuffer(value: sampleBuffer)
        dispatchToWorkspaceOutputMainActor { self?.receiveRecordVideo(sample.value) }
      },
      mainAudioMix: { [weak self] sampleBuffer in
        let sample = WorkspaceSendableSampleBuffer(value: sampleBuffer)
        guard let self else { return }
        let deliveries = self.recordAudioDeliveries
        deliveries.begin()
        dispatchToWorkspaceOutputMainActor { [weak self, deliveries] in
          defer { deliveries.end() }
          self?.receiveRecordMainAudio(sample.value)
        }
      })
  }

  func appendRecordInputAudio(_ sampleBuffer: CMSampleBuffer, trackID: String) {
    if routeLatePreCutAudioIfNeeded(
      .inputAudio(sampleBuffer, trackID: trackID),
      presentationTime: sampleBuffer.presentationTimeStamp
    ) {
      return
    }
    if recordCutBoundary != nil {
      appendToRecordCutBoundary(.inputAudio(sampleBuffer, trackID: trackID))
      return
    }
    recordService?.appendInputAudio(sampleBuffer, trackID: trackID)
  }

  func receiveRecordMainAudio(_ sampleBuffer: CMSampleBuffer) {
    if let formatDescription = sampleBuffer.formatDescription {
      latestMainAudioFormatDescription = formatDescription
    }
    if routeLatePreCutAudioIfNeeded(
      .mainAudio(sampleBuffer),
      presentationTime: sampleBuffer.presentationTimeStamp
    ) {
      return
    }
    if recordCutBoundary != nil {
      appendToRecordCutBoundary(.mainAudio(sampleBuffer))
      return
    }
    recordService?.appendMainAudioMix(sampleBuffer)
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
      let recordService, recordService.hasAcceptedFirstVideo,
      !isRecordCutCoolingDown, !isRecordCutPending
    else { return false }
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
    if recordCutBoundary != nil {
      appendToRecordCutBoundary(.video(sampleBuffer))
      return
    }
    guard isRecordCutPending, Self.isSyncVideoSample(sampleBuffer),
      let previous = recordService
    else {
      recordService?.appendMainVideo(sampleBuffer)
      return
    }

    let boundaryID = UUID()
    recordCutBoundary = RecordCutBoundary(
      id: boundaryID,
      operationID: operationID,
      previous: previous,
      firstPresentationTime: sampleBuffer.presentationTimeStamp,
      latestPresentationTime: sampleBuffer.presentationTimeStamp,
      samples: [.video(sampleBuffer)],
      mainAudioFormatDescription: latestMainAudioFormatDescription,
      isCommitEnqueued: false)
    enqueueRecordCutCommitIfReady(boundaryID)
  }

  private func appendToRecordCutBoundary(_ sample: RecordBoundarySample) {
    guard var boundary = recordCutBoundary else { return }
    let presentationTime = presentationTimeStamp(of: sample)
    if Self.isAudio(sample), presentationTime.isNumeric,
      boundary.firstPresentationTime.isNumeric,
      CMTimeCompare(presentationTime, boundary.firstPresentationTime) < 0
    {
      deliver(sample, to: boundary.previous)
      return
    }
    boundary.samples.append(sample)
    if case .mainAudio(let sampleBuffer) = sample,
      let formatDescription = sampleBuffer.formatDescription
    {
      boundary.mainAudioFormatDescription = formatDescription
    }
    if presentationTime.isNumeric,
      !boundary.latestPresentationTime.isNumeric
        || CMTimeCompare(presentationTime, boundary.latestPresentationTime) > 0
    {
      boundary.latestPresentationTime = presentationTime
    }
    recordCutBoundary = boundary
    enqueueRecordCutCommitIfReady(boundary.id)
    guard boundary.firstPresentationTime.isNumeric,
      boundary.latestPresentationTime.isNumeric,
      CMTimeCompare(
        CMTimeSubtract(boundary.latestPresentationTime, boundary.firstPresentationTime),
        CMTime(seconds: 60, preferredTimescale: 600)) > 0
    else { return }
    failRecordCutBoundary(
      boundary.id,
      message: "Cut commit exceeded the 60-second boundary buffer limit")
  }

  private func enqueueRecordCutCommitIfReady(_ boundaryID: UUID) {
    guard var boundary = recordCutBoundary, boundary.id == boundaryID,
      !boundary.isCommitEnqueued,
      boundary.mainAudioFormatDescription != nil,
      let enqueueRecordControl
    else { return }
    boundary.isCommitEnqueued = true
    recordCutBoundary = boundary
    let accepted = enqueueRecordControl { [weak self] in
      self?.commitRecordCutBoundary(boundaryID)
    }
    guard accepted else {
      failRecordCutBoundary(boundaryID, message: "Workspace control queue rejected Cut commit")
      return
    }
  }

  private static func isAudio(_ sample: RecordBoundarySample) -> Bool {
    switch sample {
    case .mainAudio, .inputAudio: true
    case .video: false
    }
  }

  private func presentationTimeStamp(of sample: RecordBoundarySample) -> CMTime {
    switch sample {
    case .video(let sampleBuffer), .mainAudio(let sampleBuffer),
      .inputAudio(let sampleBuffer, _):
      sampleBuffer.presentationTimeStamp
    }
  }

  private func commitRecordCutBoundary(_ boundaryID: UUID) {
    guard let boundary = recordCutBoundary, boundary.id == boundaryID else { return }
    guard lifecycleState == .running, operationID == boundary.operationID,
      recordService === boundary.previous, let makeRecordService
    else {
      rollbackRecordCutBoundary(boundaryID)
      return
    }
    guard case .video(let firstVideo) = boundary.samples.first else {
      failRecordCutBoundary(boundaryID, message: "Cut boundary has no first video sample")
      return
    }
    guard let mainAudioFormatDescription = boundary.mainAudioFormatDescription else {
      failRecordCutBoundary(boundaryID, message: "Cut boundary has no Main Mix format")
      return
    }
    var replacement: (any SessionRecordServicing)?
    do {
      let next = try makeRecordService()
      replacement = next
      var startResult: Result<Void, any Error>?
      next.start { startResult = $0 }
      if case .failure(let error) = startResult { throw error }
      try next.acceptFirstVideo(
        firstVideo,
        mainAudioFormatDescription: mainAudioFormatDescription)
      recordService = next
      recordCutBoundary = nil
      isRecordCutPending = false
      for sample in boundary.samples.dropFirst() { deliver(sample, to: next) }
      recordEventHandler?("Recording package started: \(next.packageDirectory.path)")
      deferPreviousRecordFinalizationUntilAudioDeliveryDrains(boundary)
    } catch {
      if let replacement { cancelReplacementRecordService(replacement) }
      failRecordCutBoundary(boundaryID, message: error.localizedDescription)
    }
  }

  private func cancelReplacementRecordService(_ service: any SessionRecordServicing) {
    let id = ObjectIdentifier(service)
    cancellingRecordServices[id] = service
    service.cancelBeforeFirstVideo { [weak self] _ in
      self?.cancellingRecordServices[id] = nil
    }
  }

  private func failRecordCutBoundary(_ boundaryID: UUID, message: String) {
    guard rollbackRecordCutBoundary(boundaryID) else { return }
    recordEventHandler?("Cut failed; recording continues: \(message)")
  }

  @discardableResult
  private func rollbackRecordCutBoundary(_ boundaryID: UUID? = nil) -> Bool {
    guard let boundary = recordCutBoundary,
      boundaryID == nil || boundary.id == boundaryID
    else { return false }
    recordCutBoundary = nil
    isRecordCutPending = false
    if recordService === boundary.previous {
      for sample in boundary.samples { deliver(sample, to: boundary.previous) }
    }
    return true
  }

  private func deliver(_ sample: RecordBoundarySample, to service: any SessionRecordServicing) {
    switch sample {
    case .video(let sampleBuffer): service.appendMainVideo(sampleBuffer)
    case .mainAudio(let sampleBuffer): service.appendMainAudioMix(sampleBuffer)
    case .inputAudio(let sampleBuffer, let trackID):
      service.appendInputAudio(sampleBuffer, trackID: trackID)
    }
  }

  private func routeLatePreCutAudioIfNeeded(
    _ sample: RecordBoundarySample,
    presentationTime: CMTime
  ) -> Bool {
    guard presentationTime.isNumeric else { return false }
    let fence = recordCutAudioFences.values
      .filter {
        $0.firstPresentationTime.isNumeric
          && CMTimeCompare(presentationTime, $0.firstPresentationTime) < 0
      }
      .min(by: {
        CMTimeCompare($0.firstPresentationTime, $1.firstPresentationTime) < 0
      })
    guard let fence else { return false }
    deliver(sample, to: fence.previous)
    return true
  }

  private func deferPreviousRecordFinalizationUntilAudioDeliveryDrains(
    _ boundary: RecordCutBoundary
  ) {
    guard recordAudioDeliveries.hasPendingDeliveries else {
      finalizePreviousRecordService(boundary.previous)
      return
    }
    let fence = RecordCutAudioFence(
      id: boundary.id,
      previous: boundary.previous,
      firstPresentationTime: boundary.firstPresentationTime)
    recordCutAudioFences[fence.id] = fence
    let deliveries = recordAudioDeliveries
    Task { @MainActor [weak self, deliveries] in
      await deliveries.waitForDrain()
      self?.completeRecordCutAudioFence(fence.id)
    }
  }

  private func completeRecordCutAudioFence(_ id: UUID) {
    guard let fence = recordCutAudioFences.removeValue(forKey: id) else { return }
    finalizePreviousRecordService(fence.previous)
  }

  private func releaseRecordCutAudioFences() {
    let fences = Array(recordCutAudioFences.values)
    recordCutAudioFences.removeAll()
    for fence in fences { finalizePreviousRecordService(fence.previous) }
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

  private static func isSyncVideoSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return false }
    let attachments =
      CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    return attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
  }

  func installYouTubeService(
    _ service: YouTubeOutputWorkspaceService, on hub: ProgramOutputMediaHub
  ) {
    youtubeService = service
    youtubeSubscription = hub.subscribe(
      mainVideo: { sampleBuffer in
        service.appendMainVideo(sampleBuffer)
      },
      mainAudioMix: { sampleBuffer in
        service.appendMainAudioMix(sampleBuffer)
      })
  }

  func stopServices() async -> Result<Void, any Error> {
    let recordResult = await stopRecordService()
    let youtubeResult = await stopYouTubeService()
    if case .failure = recordResult { return recordResult }
    return youtubeResult
  }

  func stopServicesPreservingIncompleteRecording() async -> Result<Void, any Error> {
    let recordResult = await stopRecordServicePreservingIncompletePackage()
    let youtubeResult = await stopYouTubeService()
    if case .failure = recordResult { return recordResult }
    return youtubeResult
  }

  private func stopRecordServicePreservingIncompletePackage() async -> Result<Void, any Error> {
    await drainAndRemoveRecordInputAudioSubscriptions()
    if let recordSubscription, let hub = currentMediaHub {
      hub.unsubscribe(recordSubscription)
    }
    recordSubscription = nil
    cancelRecordCut()
    releaseRecordCutAudioFences()
    releaseAllRecordAuxiliaryOperations()
    guard let service = recordService else {
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
    if let recordSubscription, let hub = currentMediaHub {
      hub.unsubscribe(recordSubscription)
    }
    recordSubscription = nil
    cancelRecordCut()
    releaseRecordCutAudioFences()
    releaseAllRecordAuxiliaryOperations()
    guard let service = recordService else {
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

  private func cancelRecordCut() {
    isRecordCutPending = false
    isRecordCutCoolingDown = false
    cutCooldownTask?.cancel()
    cutCooldownTask = nil
    rollbackRecordCutBoundary()
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
    if let youtubeSubscription, let hub = currentMediaHub {
      hub.unsubscribe(youtubeSubscription)
    }
    youtubeSubscription = nil
    guard let service = youtubeService else { return .success(()) }
    let result = await withCheckedContinuation { continuation in
      service.stop { continuation.resume(returning: $0) }
    }
    if youtubeService === service { youtubeService = nil }
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

private final class RecordAudioDeliveryTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var pendingDeliveryCount = 0
  private var drainContinuations: [CheckedContinuation<Void, Never>] = []

  func begin() {
    lock.withLock { pendingDeliveryCount += 1 }
  }

  var hasPendingDeliveries: Bool {
    lock.withLock { pendingDeliveryCount > 0 }
  }

  func end() {
    let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      pendingDeliveryCount -= 1
      guard pendingDeliveryCount == 0 else { return [] }
      let continuations = drainContinuations
      drainContinuations = []
      return continuations
    }
    continuations.forEach { $0.resume() }
  }

  func waitForDrain() async {
    await withCheckedContinuation { continuation in
      let resumeImmediately = lock.withLock { () -> Bool in
        guard pendingDeliveryCount > 0 else { return true }
        drainContinuations.append(continuation)
        return false
      }
      if resumeImmediately { continuation.resume() }
    }
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

private func dispatchToWorkspaceOutputMainActor(
  _ operation: @escaping @MainActor @Sendable () -> Void
) {
  Task { @MainActor in operation() }
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
