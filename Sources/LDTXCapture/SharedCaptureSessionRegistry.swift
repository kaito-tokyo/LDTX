// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import OSLog

struct SharedCaptureSessionVideoDemand: Equatable, Sendable {
    var deviceID: String
    var targetWidth: Int
    var targetHeight: Int
    var frameRate: Int

    init(
        deviceID: String,
        targetWidth: Int,
        targetHeight: Int,
        frameRate: Int
    ) {
        self.deviceID = deviceID
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.frameRate = frameRate
    }

    var pixelCount: Int {
        targetWidth * targetHeight
    }
}

struct SharedCaptureSessionSubscriptionDemand: Equatable, Sendable {
    var video: SharedCaptureSessionVideoDemand?
    var audioDeviceID: String?

    init(
        video: SharedCaptureSessionVideoDemand? = nil,
        audioDeviceID: String? = nil
    ) {
        self.video = video
        self.audioDeviceID = audioDeviceID
    }
}

struct SharedCaptureSessionRouteInterest: Hashable, Sendable {
    var deviceID: String
    var kind: CameraCaptureSampleKind

    init(deviceID: String, kind: CameraCaptureSampleKind) {
        self.deviceID = deviceID
        self.kind = kind
    }
}

struct SharedCaptureSessionPlan: Equatable, Sendable {
    struct Key: Hashable, Sendable {
        var groupedDeviceIDs: [String]
    }

    var key: Key
    var request: CaptureSessionRequest
    var subscriptionRoutes: [UUID: Set<SharedCaptureSessionRouteInterest>]
}

enum SharedCaptureSessionPlanner {
    static func makePlans(
        subscriptions: [UUID: SharedCaptureSessionSubscriptionDemand],
        cameras: [CameraCaptureSource],
        audioDevices: [AudioCaptureSource]
    ) -> [SharedCaptureSessionPlan] {
        let cameraLookup = Dictionary(uniqueKeysWithValues: cameras.map { ($0.id, Set([$0.id] + $0.linkedDeviceIDs)) })
        let audioLookup = Dictionary(uniqueKeysWithValues: audioDevices.map { ($0.id, Set([$0.id] + $0.linkedDeviceIDs)) })

        let expandedSubscriptions = subscriptions.map { id, demand in
            ExpandedSubscription(
                id: id,
                demand: demand,
                groupedDeviceIDs: groupedDeviceIDs(
                    for: demand,
                    cameraLookup: cameraLookup,
                    audioLookup: audioLookup
                ),
                routeInterests: routeInterests(for: demand)
            )
        }
        let subscriptionsByID = Dictionary(uniqueKeysWithValues: expandedSubscriptions.map { ($0.id, $0) })
        var remainingIDs = Set(expandedSubscriptions.map(\.id))
        var components: [[ExpandedSubscription]] = []

        while let rootID = remainingIDs.first {
            remainingIDs.remove(rootID)
            guard let root = subscriptionsByID[rootID] else {
                continue
            }

            var component: [ExpandedSubscription] = []
            var queue: [ExpandedSubscription] = [root]
            var groupedIDs = root.groupedDeviceIDs

            while !queue.isEmpty {
                let current = queue.removeFirst()
                component.append(current)

                let matchingIDs = remainingIDs.filter { candidateID in
                    guard let candidate = subscriptionsByID[candidateID] else {
                        return false
                    }
                    return !groupedIDs.isDisjoint(with: candidate.groupedDeviceIDs)
                }

                for candidateID in matchingIDs {
                    remainingIDs.remove(candidateID)
                    guard let candidate = subscriptionsByID[candidateID] else {
                        continue
                    }
                    groupedIDs.formUnion(candidate.groupedDeviceIDs)
                    queue.append(candidate)
                }
            }

            components.append(component)
        }

        return components
            .map(makePlan(component:))
            .sorted { lhs, rhs in
                lhs.key.groupedDeviceIDs.lexicographicallyPrecedes(rhs.key.groupedDeviceIDs)
            }
    }

    private static func makePlan(component: [ExpandedSubscription]) -> SharedCaptureSessionPlan {
        var groupedDeviceIDs: Set<String> = []
        var videoDemandsByDeviceID: [String: SharedCaptureSessionVideoDemand] = [:]
        var audioDeviceIDs: Set<String> = []
        var subscriptionRoutes: [UUID: Set<SharedCaptureSessionRouteInterest>] = [:]

        for subscription in component {
            groupedDeviceIDs.formUnion(subscription.groupedDeviceIDs)
            if let video = subscription.demand.video {
                if let existing = videoDemandsByDeviceID[video.deviceID] {
                    videoDemandsByDeviceID[video.deviceID] = preferredVideoDemand(existing, video)
                } else {
                    videoDemandsByDeviceID[video.deviceID] = video
                }
            }
            if let audioDeviceID = subscription.demand.audioDeviceID {
                audioDeviceIDs.insert(audioDeviceID)
            }
            subscriptionRoutes[subscription.id] = subscription.routeInterests
        }

        let videoInputs = videoDemandsByDeviceID.values
            .sorted { lhs, rhs in
                lhs.deviceID.localizedStandardCompare(rhs.deviceID) == .orderedAscending
            }
            .map { demand in
                CaptureSessionVideoRequest(
                    sourceKey: "video:\(demand.deviceID)",
                    deviceID: demand.deviceID,
                    targetWidth: demand.targetWidth,
                    targetHeight: demand.targetHeight,
                    frameRate: demand.frameRate
                )
            }
        let audioInputs = audioDeviceIDs
            .sorted { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .map { deviceID in
                CaptureSessionAudioRequest(
                    sourceKey: "audio:\(deviceID)",
                    deviceID: deviceID
                )
            }

        return SharedCaptureSessionPlan(
            key: SharedCaptureSessionPlan.Key(
                groupedDeviceIDs: groupedDeviceIDs.sorted { lhs, rhs in
                    lhs.localizedStandardCompare(rhs) == .orderedAscending
                }
            ),
            request: CaptureSessionRequest(
                videoInputs: videoInputs,
                audioInputs: audioInputs
            ),
            subscriptionRoutes: subscriptionRoutes
        )
    }

    private static func groupedDeviceIDs(
        for demand: SharedCaptureSessionSubscriptionDemand,
        cameraLookup: [String: Set<String>],
        audioLookup: [String: Set<String>]
    ) -> Set<String> {
        var identifiers: Set<String> = []
        if let video = demand.video {
            identifiers.formUnion(cameraLookup[video.deviceID] ?? [video.deviceID])
        }
        if let audioDeviceID = demand.audioDeviceID {
            identifiers.formUnion(audioLookup[audioDeviceID] ?? [audioDeviceID])
        }
        return identifiers
    }

    private static func routeInterests(
        for demand: SharedCaptureSessionSubscriptionDemand
    ) -> Set<SharedCaptureSessionRouteInterest> {
        var interests: Set<SharedCaptureSessionRouteInterest> = []
        if let video = demand.video {
            interests.insert(SharedCaptureSessionRouteInterest(
                deviceID: video.deviceID,
                kind: .video
            ))
        }
        if let audioDeviceID = demand.audioDeviceID {
            interests.insert(SharedCaptureSessionRouteInterest(
                deviceID: audioDeviceID,
                kind: .audio
            ))
        }
        return interests
    }

    private static func preferredVideoDemand(
        _ lhs: SharedCaptureSessionVideoDemand,
        _ rhs: SharedCaptureSessionVideoDemand
    ) -> SharedCaptureSessionVideoDemand {
        if lhs.pixelCount != rhs.pixelCount {
            return lhs.pixelCount > rhs.pixelCount ? lhs : rhs
        }
        if lhs.frameRate != rhs.frameRate {
            return lhs.frameRate > rhs.frameRate ? lhs : rhs
        }
        if lhs.targetWidth != rhs.targetWidth {
            return lhs.targetWidth > rhs.targetWidth ? lhs : rhs
        }
        if lhs.targetHeight != rhs.targetHeight {
            return lhs.targetHeight > rhs.targetHeight ? lhs : rhs
        }
        return lhs.deviceID.localizedStandardCompare(rhs.deviceID) != .orderedDescending ? lhs : rhs
    }

    private struct ExpandedSubscription {
        var id: UUID
        var demand: SharedCaptureSessionSubscriptionDemand
        var groupedDeviceIDs: Set<String>
        var routeInterests: Set<SharedCaptureSessionRouteInterest>
    }
}

enum SharedCaptureFailureRouter {
    static func subscriptionIDs(
        for failure: CaptureSessionRuntimeFailure,
        routesBySubscriptionID: [UUID: Set<SharedCaptureSessionRouteInterest>]
    ) -> Set<UUID> {
        switch failure {
        case let .deviceDisconnected(deviceID),
             let .audioFormatChanged(deviceID, _, _):
            return Set(routesBySubscriptionID.compactMap { subscriptionID, routes in
                routes.contains(where: { $0.deviceID == deviceID }) ? subscriptionID : nil
            })
        default:
            return Set(routesBySubscriptionID.keys)
        }
    }
}

final class SharedCaptureSessionRegistry: @unchecked Sendable {
    static let shared = SharedCaptureSessionRegistry()
    private static let logger = Logger(
        subsystem: "tokyo.kaito.ldtx",
        category: "SharedCaptureSessionRegistry"
    )
    private static let signpostLog = OSLog(
        subsystem: "tokyo.kaito.ldtx",
        category: "PointsOfInterest"
    )

    typealias SampleHandler = CameraCaptureService.SampleHandler
    typealias FailureHandler = CameraCaptureService.FailureHandler

    struct PendingSubscription {
        var demand: SharedCaptureSessionSubscriptionDemand
        var failureHandler: FailureHandler
        var handler: SampleHandler

        init(
            demand: SharedCaptureSessionSubscriptionDemand,
            failureHandler: @escaping FailureHandler = { _ in },
            handler: @escaping SampleHandler
        ) {
            self.demand = demand
            self.failureHandler = failureHandler
            self.handler = handler
        }
    }

    private struct SubscriptionRecord {
        var demand: SharedCaptureSessionSubscriptionDemand
        var failureHandler: FailureHandler
        var handler: SampleHandler
    }

    private var subscriptions: [UUID: SubscriptionRecord] = [:]
    private var sessionsByKey: [SharedCaptureSessionPlan.Key: SharedCaptureSession] = [:]
    private let registryQueue = DispatchQueue(label: "tokyo.kaito.ldtx.SharedCaptureSessionRegistry")

    func register(
        id: UUID,
        demand: SharedCaptureSessionSubscriptionDemand,
        handler: @escaping SampleHandler,
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        registryQueue.async { [self] in
            replaceOnRegistryQueue(
                ids: [],
                with: [PendingSubscription(demand: demand, handler: handler)],
                assignedIDs: [id]
            ) { result in
                completionHandler(result.map { _ in () })
            }
        }
    }

    func unregister(ids: [UUID], completionHandler: @escaping @Sendable () -> Void = {}) {
        replace(ids: ids, with: []) { _ in completionHandler() }
    }

    func replace(
        ids oldIDs: [UUID],
        with pendingSubscriptions: [PendingSubscription],
        completionHandler: @escaping @Sendable (Result<[UUID], any Error>) -> Void
    ) {
        registryQueue.async { [self] in
            replaceOnRegistryQueue(
                ids: oldIDs,
                with: pendingSubscriptions,
                assignedIDs: nil,
                completionHandler: completionHandler
            )
        }
    }

    private func reconcileSessions(
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(registryQueue))
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "Shared Capture Reconcile", signpostID: signpostID)
        let finish: @Sendable (Result<Void, any Error>) -> Void = { result in
            os_signpost(.end, log: Self.signpostLog, name: "Shared Capture Reconcile", signpostID: signpostID)
            completionHandler(result)
        }

        let catalog = CaptureSessionManager()
        let plans = SharedCaptureSessionPlanner.makePlans(
            subscriptions: subscriptions.mapValues(\.demand),
            cameras: catalog.availableCameras(),
            audioDevices: catalog.availableAudioDevices()
        )
        let plansByKey = Dictionary(uniqueKeysWithValues: plans.map { ($0.key, $0) })
        let subscriptionCount = self.subscriptions.count
        Self.logger.notice(
            "Reconciling shared capture sessions: subscriptions=\(subscriptionCount, privacy: .public), plans=\(plans.count, privacy: .public), planSummary=\(Self.describePlans(plans), privacy: .public)"
        )

        let obsoleteKeys = Array(sessionsByKey.keys).filter { plansByKey[$0] == nil }
        stopObsoleteSessions(obsoleteKeys, index: 0) { [self] in
            reconcilePlans(plans, index: 0, completionHandler: finish)
        }
    }

    private func stopObsoleteSessions(
        _ keys: [SharedCaptureSessionPlan.Key],
        index: Int,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(registryQueue))
        guard index < keys.count else {
            completionHandler()
            return
        }
        let key = keys[index]
        guard let session = sessionsByKey.removeValue(forKey: key) else {
            stopObsoleteSessions(keys, index: index + 1, completionHandler: completionHandler)
            return
        }
        Self.logger.notice(
            "Stopping shared capture session with no remaining plan: key=\(Self.describePlanKey(key), privacy: .public)"
        )
        session.stop { [self] in
            registryQueue.async {
                self.stopObsoleteSessions(keys, index: index + 1, completionHandler: completionHandler)
            }
        }
    }

    private func reconcilePlans(
        _ plans: [SharedCaptureSessionPlan],
        index: Int,
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(registryQueue))
        guard index < plans.count else {
            completionHandler(.success(()))
            return
        }
        let plan = plans[index]
            let handlersByInterest = plan.subscriptionRoutes.reduce(into: [SharedCaptureSessionRouteInterest: [SampleHandler]]()) { result, entry in
                guard let subscription = subscriptions[entry.key] else {
                    return
                }
                for interest in entry.value {
                    result[interest, default: []].append(subscription.handler)
                }
            }
            let failureHandlersBySubscriptionID = plan.subscriptionRoutes.reduce(
                into: [UUID: FailureHandler]()
            ) { result, entry in
                result[entry.key] = subscriptions[entry.key]?.failureHandler
            }

            let session: SharedCaptureSession
            if let existing = sessionsByKey[plan.key] {
                Self.logger.notice(
                    "Reusing shared capture session: key=\(Self.describePlanKey(plan.key), privacy: .public), request=\(Self.describeRequest(plan.request), privacy: .public), subscribers=\(plan.subscriptionRoutes.count, privacy: .public)"
                )
                session = existing
            } else {
                let newSession = SharedCaptureSession()
                sessionsByKey[plan.key] = newSession
                Self.logger.notice(
                    "Creating shared capture session: key=\(Self.describePlanKey(plan.key), privacy: .public), request=\(Self.describeRequest(plan.request), privacy: .public), subscribers=\(plan.subscriptionRoutes.count, privacy: .public)"
                )
                session = newSession
            }

        session.reconcile(
            request: plan.request,
            handlersByInterest: handlersByInterest,
            failureRoutesBySubscriptionID: plan.subscriptionRoutes,
            failureHandlersBySubscriptionID: failureHandlersBySubscriptionID
        ) { [self] result in
            registryQueue.async {
                switch result {
                case .success:
                    self.reconcilePlans(plans, index: index + 1, completionHandler: completionHandler)
                case let .failure(error):
                    self.sessionsByKey.removeValue(forKey: plan.key)
                    session.stop {
                        completionHandler(.failure(error))
                    }
                }
            }
        }
    }

    private func stopAllSessions(completionHandler: @escaping @Sendable () -> Void) {
        dispatchPrecondition(condition: .onQueue(registryQueue))
        let sessions = Array(sessionsByKey.values)
        sessionsByKey.removeAll(keepingCapacity: true)
        stopSessions(sessions, index: 0, completionHandler: completionHandler)
    }

    private func stopSessions(
        _ sessions: [SharedCaptureSession],
        index: Int,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        guard index < sessions.count else {
            completionHandler()
            return
        }
        sessions[index].stop { [self] in
            registryQueue.async {
                self.stopSessions(sessions, index: index + 1, completionHandler: completionHandler)
            }
        }
    }

    private func replaceOnRegistryQueue(
        ids oldIDs: [UUID],
        with pendingSubscriptions: [PendingSubscription],
        assignedIDs: [UUID]?,
        completionHandler: @escaping @Sendable (Result<[UUID], any Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(registryQueue))
        let previousSubscriptions = subscriptions
        let nextIDs = assignedIDs ?? pendingSubscriptions.map { _ in UUID() }
        let removedSubscriptions = oldIDs.compactMap { id in
            previousSubscriptions[id]
        }

        Self.logger.notice(
            "Updating shared capture subscriptions: removeCount=\(oldIDs.count, privacy: .public), addCount=\(pendingSubscriptions.count, privacy: .public), removed=\(Self.describeDemands(removedSubscriptions.map(\.demand)), privacy: .public), added=\(Self.describeDemands(pendingSubscriptions.map(\.demand)), privacy: .public)"
        )

        for id in oldIDs {
            subscriptions.removeValue(forKey: id)
        }
        for (id, pendingSubscription) in zip(nextIDs, pendingSubscriptions) {
            subscriptions[id] = SubscriptionRecord(
                demand: pendingSubscription.demand,
                failureHandler: pendingSubscription.failureHandler,
                handler: pendingSubscription.handler
            )
        }

        reconcileSessions { [self] result in
            registryQueue.async {
                switch result {
                case .success:
                    completionHandler(.success(nextIDs))
                case let .failure(error):
                    self.subscriptions = previousSubscriptions
                    self.reconcileSessions { recoveryResult in
                        self.registryQueue.async {
                            if case .failure = recoveryResult {
                                self.stopAllSessions {}
                            }
                            completionHandler(.failure(error))
                        }
                    }
                }
            }
        }
    }

    fileprivate static func describePlans(_ plans: [SharedCaptureSessionPlan]) -> String {
        if plans.isEmpty {
            return "none"
        }
        return plans.map { plan in
            "\(describePlanKey(plan.key))=>\(describeRequest(plan.request))#subs=\(plan.subscriptionRoutes.count)"
        }
        .joined(separator: "; ")
    }

    fileprivate static func describePlanKey(_ key: SharedCaptureSessionPlan.Key) -> String {
        key.groupedDeviceIDs.joined(separator: ",")
    }

    fileprivate static func describeRequest(_ request: CaptureSessionRequest) -> String {
        let video = request.videoInputs.map {
            "\($0.deviceID)@\($0.targetWidth)x\($0.targetHeight)/\($0.frameRate)"
        }.joined(separator: ",")
        let audio = request.audioInputs.map(\.deviceID).joined(separator: ",")
        return "video[\(video)] audio[\(audio)]"
    }

    fileprivate static func describeDemands(_ demands: [SharedCaptureSessionSubscriptionDemand]) -> String {
        if demands.isEmpty {
            return "none"
        }
        return demands.map(describeDemand(_:)).joined(separator: "; ")
    }

    fileprivate static func describeDemand(_ demand: SharedCaptureSessionSubscriptionDemand) -> String {
        let videoDescription: String
        if let video = demand.video {
            videoDescription = "\(video.deviceID)@\(video.targetWidth)x\(video.targetHeight)/\(video.frameRate)"
        } else {
            videoDescription = "-"
        }
        return "video=\(videoDescription),audio=\(demand.audioDeviceID ?? "-")"
    }
}

private final class SharedCaptureSession: @unchecked Sendable {
    typealias SampleHandler = CameraCaptureService.SampleHandler
    typealias FailureHandler = CameraCaptureService.FailureHandler
    private static let logger = Logger(
        subsystem: "tokyo.kaito.ldtx",
        category: "SharedCaptureSession"
    )
    private static let signpostLog = OSLog(
        subsystem: "tokyo.kaito.ldtx",
        category: "PointsOfInterest"
    )

    private let manager = CaptureSessionManager()
    private let lock = NSLock()
    private let identifier = UUID()

    private var request: CaptureSessionRequest?
    private var handlersByInterest: [SharedCaptureSessionRouteInterest: [SampleHandler]] = [:]
    private var failureRoutesBySubscriptionID: [UUID: Set<SharedCaptureSessionRouteInterest>] = [:]
    private var failureHandlersBySubscriptionID: [UUID: FailureHandler] = [:]

    func reconcile(
        request: CaptureSessionRequest,
        handlersByInterest: [SharedCaptureSessionRouteInterest: [SampleHandler]],
        failureRoutesBySubscriptionID: [UUID: Set<SharedCaptureSessionRouteInterest>],
        failureHandlersBySubscriptionID: [UUID: FailureHandler],
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "Shared Capture Session Reconcile", signpostID: signpostID)
        defer {
            os_signpost(.end, log: Self.signpostLog, name: "Shared Capture Session Reconcile", signpostID: signpostID)
        }

        let previousState = lock.withLock { () -> (CaptureSessionRequest?, [SharedCaptureSessionRouteInterest: [SampleHandler]], [UUID: Set<SharedCaptureSessionRouteInterest>], [UUID: FailureHandler]) in
            let state = (self.request, self.handlersByInterest, self.failureRoutesBySubscriptionID, self.failureHandlersBySubscriptionID)
            self.request = request
            self.handlersByInterest = handlersByInterest
            self.failureRoutesBySubscriptionID = failureRoutesBySubscriptionID
            self.failureHandlersBySubscriptionID = failureHandlersBySubscriptionID
            return state
        }

        guard previousState.0 != request else {
            Self.logger.notice(
                "Skipping shared capture session restart: session=\(self.identifier.uuidString, privacy: .public), requestUnchanged=\(SharedCaptureSessionRegistry.describeRequest(request), privacy: .public), handlerRoutes=\(handlersByInterest.count, privacy: .public)"
            )
            completionHandler(.success(()))
            return
        }

        Self.logger.notice(
            "Starting or reconfiguring shared capture session: session=\(self.identifier.uuidString, privacy: .public), previous=\(previousState.0.map(SharedCaptureSessionRegistry.describeRequest(_:)) ?? "none", privacy: .public), next=\(SharedCaptureSessionRegistry.describeRequest(request), privacy: .public), handlerRoutes=\(handlersByInterest.count, privacy: .public)"
        )

        manager.start(
            request: request,
            handler: { [weak self] sample in self?.dispatch(sample) },
            failureHandler: { [weak self] failure in self?.dispatch(failure) }
        ) { [self] result in
            if case .failure = result {
                lock.withLock {
                    self.request = previousState.0
                    self.handlersByInterest = previousState.1
                    self.failureRoutesBySubscriptionID = previousState.2
                    self.failureHandlersBySubscriptionID = previousState.3
                }
            }
            completionHandler(result)
        }
    }

    func stop(completionHandler: @escaping @Sendable () -> Void = {}) {
        Self.logger.notice(
            "Stopping shared capture session: session=\(self.identifier.uuidString, privacy: .public)"
        )
        manager.stop { [self] in
            lock.withLock {
                request = nil
                handlersByInterest.removeAll(keepingCapacity: true)
                failureRoutesBySubscriptionID.removeAll(keepingCapacity: true)
                failureHandlersBySubscriptionID.removeAll(keepingCapacity: true)
            }
            completionHandler()
        }
    }

    private func dispatch(_ sample: CapturedSample) {
        let handlers = lock.withLock {
            handlersByInterest[SharedCaptureSessionRouteInterest(
                deviceID: sample.deviceID,
                kind: sample.kind
            )] ?? []
        }
        for handler in handlers {
            handler(sample.sampleBuffer, sample.kind)
        }
    }

    private func dispatch(_ failure: CaptureSessionRuntimeFailure) {
        let handlers = lock.withLock {
            SharedCaptureFailureRouter.subscriptionIDs(
                for: failure,
                routesBySubscriptionID: failureRoutesBySubscriptionID
            ).compactMap { subscriptionID in
                failureHandlersBySubscriptionID[subscriptionID]
            }
        }
        for handler in handlers {
            handler(failure)
        }
    }
}
