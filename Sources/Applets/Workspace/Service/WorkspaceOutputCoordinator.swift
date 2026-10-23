// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXBackgroundSegmentation
import LDTXProgramRuntime
import LDTXTaskQueue
import LDTXWorkspaceAppletModel
import LDTXYouTubeRTMPS
import Observation

protocol YouTubeOutputWorkspaceServicing: AnyObject, Sendable {
  nonisolated func appendMainVideo(_ sampleBuffer: CMSampleBuffer)
  nonisolated func appendMainAudioMix(_ sampleBuffer: CMSampleBuffer)
  @MainActor func failMediaDelivery(_ error: Error)
  @MainActor func stop(
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void)
}

extension YouTubeOutputWorkspaceService: YouTubeOutputWorkspaceServicing {}

protocol YouTubeRTMPSWorkspaceServicing: AnyObject, Sendable {
  func appendLandscapeVideo(_ sampleBuffer: CMSampleBuffer)
  func appendPortraitVideo(_ sampleBuffer: CMSampleBuffer)
  func appendLandscapeAudioMix(_ sampleBuffer: CMSampleBuffer)
  func appendPortraitAudioMix(_ sampleBuffer: CMSampleBuffer)
  func failMediaDelivery(_ error: any Error)
  func finish() async -> Result<Void, any Error>
  func waitUntilPublishing() async throws
}

extension YouTubeRTMPSWorkspaceService: YouTubeRTMPSWorkspaceServicing {}

private final class WorkspaceRecordMediaCoreSlot: @unchecked Sendable {
  private let lock = NSLock()
  private var core: WorkspaceRecordMediaCore

  init(_ core: WorkspaceRecordMediaCore) { self.core = core }

  func current() -> WorkspaceRecordMediaCore { lock.withLock { core } }

  func replace(with core: WorkspaceRecordMediaCore) {
    lock.withLock { self.core = core }
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

  init() {
    queue = EventTaskQueue(label: "tokyo.kaito.ldtx.workspace.events")
  }

  @discardableResult
  func enqueue(
    _ operation: @escaping @MainActor @Sendable () async -> Void
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
        { _ in
          Task { @MainActor in
            defer {
              completionState.finish()
              completion()
            }
            await operation()
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
  var youtubeRTMPSService: (any YouTubeRTMPSWorkspaceServicing)?
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
  @ObservationIgnored private var youtubeRTMPSLandscapeSubscription:
    ProgramOutputMediaHub.Subscription?
  @ObservationIgnored private var youtubeRTMPSPortraitSubscription:
    ProgramOutputMediaHub.Subscription?
  @ObservationIgnored private var youtubeRTMPSLandscapeHub: ProgramOutputMediaHub?
  @ObservationIgnored private var youtubeRTMPSPortraitHub: ProgramOutputMediaHub?
  @ObservationIgnored private var youtubeRTMPSSubscriptionGeneration: UUID?
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
  @ObservationIgnored private let willEnqueueRecordInputAudio: @Sendable () -> Void

  init(
    sleepInhibitor: OutputSleepInhibitor = OutputSleepInhibitor(),
    recordMediaDrainTimeout: Duration = .seconds(30),
    recordCutBoundaryByteLimit: Int = 256 * 1_024 * 1_024,
    recordFinalizerTimeout: Duration = .seconds(30),
    willEnqueueRecordInputAudio: @escaping @Sendable () -> Void = {},
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
    self.willEnqueueRecordInputAudio = willEnqueueRecordInputAudio
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
    youtubeRTMPSService = nil
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
    youtubeRTMPSLandscapeSubscription = nil
    youtubeRTMPSPortraitSubscription = nil
    youtubeRTMPSLandscapeHub = nil
    youtubeRTMPSPortraitHub = nil
    youtubeRTMPSSubscriptionGeneration = nil
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
          // Native output owns its PCM independently of the capture ring.
          self.willEnqueueRecordInputAudio()
          recordMediaCore.enqueueInputAudio(
            sampleBuffer, trackID: track.trackID, callback: callback)
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
    recordSubscription =
      service.recordsLandscapeOutput
      ? hub.subscribe(
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
        }) : nil
    portraitRecordSubscription =
      service.recordsPortraitOutput
      ? portraitHub?.subscribe(
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
        }) : nil
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

  @discardableResult
  func installYouTubeRTMPSService(
    _ service: any YouTubeRTMPSWorkspaceServicing,
    landscapeHub: ProgramOutputMediaHub,
    portraitHub: ProgramOutputMediaHub,
    limits: ProgramOutputMediaChannelLimits = .default
  ) -> Bool {
    guard youtubeRTMPSService == nil,
      youtubeRTMPSLandscapeSubscription == nil,
      youtubeRTMPSPortraitSubscription == nil,
      youtubeRTMPSLandscapeHub == nil,
      youtubeRTMPSPortraitHub == nil,
      youtubeRTMPSSubscriptionGeneration == nil
    else { return false }
    youtubeRTMPSService = service
    youtubeRTMPSLandscapeHub = landscapeHub
    youtubeRTMPSPortraitHub = portraitHub
    let subscriptionGeneration = UUID()
    youtubeRTMPSSubscriptionGeneration = subscriptionGeneration
    youtubeRTMPSLandscapeSubscription = landscapeHub.subscribe(
      limits: limits,
      mainVideo: service.appendLandscapeVideo,
      mainAudioMix: service.appendLandscapeAudioMix,
      failureHandler: { [weak self, weak service] error in
        Task { @MainActor in
          guard let self, let service, self.youtubeRTMPSService === service else { return }
          service.failMediaDelivery(error)
          await self.removeYouTubeRTMPSSubscriptions(generation: subscriptionGeneration)
        }
      })
    youtubeRTMPSPortraitSubscription = portraitHub.subscribe(
      limits: limits,
      mainVideo: service.appendPortraitVideo,
      mainAudioMix: service.appendPortraitAudioMix,
      failureHandler: { [weak self, weak service] error in
        Task { @MainActor in
          guard let self, let service, self.youtubeRTMPSService === service else { return }
          service.failMediaDelivery(error)
          await self.removeYouTubeRTMPSSubscriptions(generation: subscriptionGeneration)
        }
      })
    return true
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
    async let dashResult = stopDASHYouTubeService()
    async let rtmpsResult = stopYouTubeRTMPSService()
    let results = await (dashResult, rtmpsResult)
    if case .failure = results.0 { return results.0 }
    return results.1
  }

  private func stopDASHYouTubeService() async -> Result<Void, any Error> {
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

  private func stopYouTubeRTMPSService() async -> Result<Void, any Error> {
    let landscapeSubscription = youtubeRTMPSLandscapeSubscription
    let landscapeHub = youtubeRTMPSLandscapeHub
    let portraitSubscription = youtubeRTMPSPortraitSubscription
    let portraitHub = youtubeRTMPSPortraitHub
    let service = youtubeRTMPSService
    youtubeRTMPSSubscriptionGeneration = nil
    async let landscapeDrain = Self.drainRTMPSSubscription(
      landscapeSubscription, from: landscapeHub)
    async let portraitDrain = Self.drainRTMPSSubscription(
      portraitSubscription, from: portraitHub)
    let drainResults = await (landscapeDrain, portraitDrain)
    var mediaDrainFailure: (any Error)?
    if case .failure(let error) = drainResults.0 {
      mediaDrainFailure = error
    } else if case .failure(let error) = drainResults.1 {
      mediaDrainFailure = error
    }
    if youtubeRTMPSSubscriptionGeneration == nil {
      youtubeRTMPSLandscapeSubscription = nil
      youtubeRTMPSPortraitSubscription = nil
      youtubeRTMPSLandscapeHub = nil
      youtubeRTMPSPortraitHub = nil
    }
    guard let service else {
      if let mediaDrainFailure { return .failure(mediaDrainFailure) }
      return .success(())
    }
    if let mediaDrainFailure { service.failMediaDelivery(mediaDrainFailure) }
    let result = await service.finish()
    if youtubeRTMPSService === service { youtubeRTMPSService = nil }
    if let mediaDrainFailure { return .failure(mediaDrainFailure) }
    return result
  }

  private func removeYouTubeRTMPSSubscriptions(generation: UUID) async {
    guard youtubeRTMPSSubscriptionGeneration == generation else { return }
    youtubeRTMPSSubscriptionGeneration = nil
    let landscapeSubscription = youtubeRTMPSLandscapeSubscription
    let landscapeHub = youtubeRTMPSLandscapeHub
    let portraitSubscription = youtubeRTMPSPortraitSubscription
    let portraitHub = youtubeRTMPSPortraitHub
    async let landscapeDrain = Self.drainRTMPSSubscription(
      landscapeSubscription, from: landscapeHub)
    async let portraitDrain = Self.drainRTMPSSubscription(
      portraitSubscription, from: portraitHub)
    _ = await (landscapeDrain, portraitDrain)
    guard youtubeRTMPSSubscriptionGeneration == nil else { return }
    youtubeRTMPSLandscapeSubscription = nil
    youtubeRTMPSPortraitSubscription = nil
    youtubeRTMPSLandscapeHub = nil
    youtubeRTMPSPortraitHub = nil
  }

  private static func drainRTMPSSubscription(
    _ subscription: ProgramOutputMediaHub.Subscription?,
    from hub: ProgramOutputMediaHub?
  ) async -> Result<Void, ProgramOutputMediaChannelError> {
    guard let subscription, let hub else { return .success(()) }
    return await hub.unsubscribeAndDrain(subscription)
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
