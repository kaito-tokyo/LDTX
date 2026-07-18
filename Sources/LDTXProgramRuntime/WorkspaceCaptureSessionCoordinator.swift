// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import Foundation
import LDTXCapture
import LDTXProgram
import OSLog

public final class WorkspaceCaptureSessionCoordinator: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "tokyo.kaito.ldtx",
        category: "WorkspaceCaptureSessionCoordinator"
    )
    private var tickHandlersByObserver: [UUID: @Sendable (UInt64) -> Void] = [:]
    private var capturesByCameraID: [String: WorkspaceCaptureSessionCapture] = [:]
    private var inputDeviceCaptureRequests: Set<WorkspaceCaptureSessionRequest> = []
    private var isStopping = false
    private var pendingStartCount = 0
    private var pendingStopCount = 0
    private var stopCompletionHandlers: [@Sendable () -> Void] = []
    private var tick: UInt64 = 0
    private let stateLock = NSRecursiveLock()
    private let captureServiceFactory: @Sendable () -> any CameraCaptureStreaming

    public init(
        captureServiceFactory: @escaping @Sendable () -> any CameraCaptureStreaming = {
            CameraCaptureService()
        }
    ) {
        self.captureServiceFactory = captureServiceFactory
    }

    public func synchronizeInputDeviceCaptures(
        inputDevices: [ProgramInputDeviceRecord],
        availableCameraIDs: Set<String>,
        canvasWidth: Int,
        canvasHeight: Int,
        frameRate: Int,
        completionHandler: @escaping @Sendable (Set<String>) -> Void
    ) {
        guard stateLock.withLock({ !isStopping }) else {
            completionHandler(Set(inputDevices.compactMap(\.physicalDeviceID)))
            return
        }
        let nextRequests = Set<WorkspaceCaptureSessionRequest>(
            inputDevices.compactMap { inputDevice in
                guard inputDevice.kind == .video,
                      !inputDevice.isMuted,
                      let cameraID = inputDevice.physicalDeviceID,
                      !cameraID.isEmpty,
                      availableCameraIDs.contains(cameraID) else {
                    return nil
                }
                return Self.inputDeviceCaptureRequest(
                    for: cameraID,
                    inputDevice: inputDevice,
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight,
                    frameRate: frameRate
                )
            }
        )
        let cameraIDs = stateLock.withLock { () -> Set<String> in
            let previousRequests = inputDeviceCaptureRequests
            inputDeviceCaptureRequests = nextRequests
            return affectedCameraIDs(
                previousRequests: previousRequests,
                nextRequests: nextRequests
            )
        }
        synchronizeCaptures(
            for: Array(cameraIDs),
            failedCameraIDs: [],
            completionHandler: completionHandler
        )
    }

    public func releaseInputDeviceCaptures(
        completionHandler: @escaping @Sendable () -> Void = {}
    ) {
        let cameraIDs = stateLock.withLock { () -> [String] in
            let previousRequests = inputDeviceCaptureRequests
            inputDeviceCaptureRequests = []
            return Array(Set(previousRequests.map(\.cameraID)))
        }
        synchronizeCaptures(
            for: cameraIDs,
            failedCameraIDs: []
        ) { _ in
            completionHandler()
        }
    }

    public func restartAllCaptureSessions(
        completionHandler: @escaping @Sendable (Set<String>) -> Void
    ) {
        guard stateLock.withLock({ !isStopping }) else {
            completionHandler([])
            return
        }
        let captures = stateLock.withLock {
            Array(capturesByCameraID.values)
        }
        restartCaptures(
            captures,
            failedCameraIDs: [],
            completionHandler: completionHandler
        )
    }

    private func restartCaptures(
        _ captures: [WorkspaceCaptureSessionCapture],
        failedCameraIDs: Set<String>,
        completionHandler: @escaping @Sendable (Set<String>) -> Void
    ) {
        guard let capture = captures.first else {
            completionHandler(failedCameraIDs)
            return
        }
        let remainingCaptures = Array(captures.dropFirst())
        let request = stateLock.withLock { capture.request }
        capture.captureService.stop { [weak self] in
            guard let self else {
                completionHandler(failedCameraIDs.union([request.cameraID]))
                return
            }
            self.stateLock.withLock {
                self.resetState(for: capture)
            }
            self.startCapture(request: request, capture: capture) { result in
                var nextFailures = failedCameraIDs
                if case .failure = result {
                    nextFailures.insert(request.cameraID)
                }
                self.restartCaptures(
                    remainingCaptures,
                    failedCameraIDs: nextFailures,
                    completionHandler: completionHandler
                )
            }
        }
    }

    public func latestPixelBuffer(forCameraID cameraID: String) -> CVPixelBuffer? {
        latestFrame(forCameraID: cameraID)?.pixelBuffer
    }

    func latestFrame(forCameraID cameraID: String) -> CapturedVideoFrame? {
        stateLock.withLock {
            guard let capture = capturesByCameraID[cameraID] else { return nil }
            return capture.latestFrame
        }
    }

    @discardableResult
    func addTickHandler(_ handler: @escaping @Sendable (UInt64) -> Void) -> UUID {
        stateLock.withLock {
            let observerID = UUID()
            tickHandlersByObserver[observerID] = handler
            handler(tick)
            return observerID
        }
    }

    func removeTickHandler(_ observerID: UUID) {
        _ = stateLock.withLock {
            tickHandlersByObserver.removeValue(forKey: observerID)
        }
    }

    public func stopAndReset(completionHandler: @escaping @Sendable () -> Void = {}) {
        let captureServices = stateLock.withLock { () -> [any CameraCaptureStreaming] in
            isStopping = true
            stopCompletionHandlers.append(completionHandler)
            inputDeviceCaptureRequests = []
            let services = capturesByCameraID.values.map(\.captureService)
            capturesByCameraID = [:]
            pendingStopCount += services.count
            return services
        }
        for captureService in captureServices {
            captureService.stop { [weak self] in
                self?.completePendingStop()
            }
        }
        finishStopIfPossible()
    }

    public func isFullyStopped() -> Bool {
        stateLock.withLock {
            !isStopping && pendingStartCount == 0 && pendingStopCount == 0
                && capturesByCameraID.isEmpty
        }
    }

    private func completePendingStop() {
        stateLock.withLock {
            pendingStopCount -= 1
        }
        finishStopIfPossible()
    }

    private func finishStopIfPossible() {
        let handlers = stateLock.withLock { () -> [@Sendable () -> Void] in
            guard isStopping, pendingStartCount == 0, pendingStopCount == 0 else { return [] }
            isStopping = false
            let handlers = stopCompletionHandlers
            stopCompletionHandlers = []
            return handlers
        }
        handlers.forEach { $0() }
    }

    private static func inputDeviceCaptureRequest(
        for cameraID: String,
        inputDevice: ProgramInputDeviceRecord,
        canvasWidth: Int,
        canvasHeight: Int,
        frameRate: Int
    ) -> WorkspaceCaptureSessionRequest {
        WorkspaceCaptureSessionRequest(
            cameraID: cameraID,
            width: inputDevice.captureWidthOverride ?? canvasWidth,
            height: inputDevice.captureHeightOverride ?? canvasHeight,
            frameRate: inputDevice.captureFrameRateOverride ?? frameRate
        )
    }

    private func stopCapture(
        cameraID: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        guard let capture = stateLock.withLock({
            capturesByCameraID.removeValue(forKey: cameraID)
        }) else {
            completionHandler()
            return
        }
        capture.captureService.stop(completionHandler: completionHandler)
    }

    private func synchronizeCaptures(
        for cameraIDs: [String],
        failedCameraIDs: Set<String>,
        completionHandler: @escaping @Sendable (Set<String>) -> Void
    ) {
        guard let cameraID = cameraIDs.first else {
            completionHandler(failedCameraIDs)
            return
        }
        synchronizeCapture(cameraID: cameraID) { [weak self] result in
            guard let self else {
                completionHandler(failedCameraIDs.union([cameraID]))
                return
            }
            var nextFailures = failedCameraIDs
            if case .failure = result {
                nextFailures.insert(cameraID)
            }
            self.synchronizeCaptures(
                for: Array(cameraIDs.dropFirst()),
                failedCameraIDs: nextFailures,
                completionHandler: completionHandler
            )
        }
    }

    private func synchronizeCapture(
        cameraID: String,
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        guard let request = stateLock.withLock({ effectiveRequest(for: cameraID) }) else {
            stopCapture(cameraID: cameraID) {
                completionHandler(.success(()))
            }
            return
        }

        if let capture = stateLock.withLock({ capturesByCameraID[cameraID] }) {
            guard stateLock.withLock({ capture.request != request }) else {
                completionHandler(.success(()))
                return
            }
            capture.captureService.stop { [weak self] in
                guard let self else {
                    completionHandler(.failure(CancellationError()))
                    return
                }
                self.stateLock.withLock {
                    self.resetState(for: capture)
                    capture.update(request: request)
                }
                self.startCapture(request: request, capture: capture) { result in
                    if case .failure = result {
                        self.stateLock.withLock {
                            if self.capturesByCameraID[cameraID] === capture {
                                self.capturesByCameraID.removeValue(forKey: cameraID)
                            }
                        }
                    }
                    completionHandler(result)
                }
            }
            return
        }

        let capture = WorkspaceCaptureSessionCapture(
            request: request,
            captureService: captureServiceFactory()
        )
        stateLock.withLock {
            capturesByCameraID[cameraID] = capture
        }
        startCapture(request: request, capture: capture) { [weak self] result in
            if case .failure = result {
                self?.stateLock.withLock {
                    if self?.capturesByCameraID[cameraID] === capture {
                        self?.capturesByCameraID.removeValue(forKey: cameraID)
                    }
                }
            }
            completionHandler(result)
        }
    }

    private func effectiveRequest(for cameraID: String) -> WorkspaceCaptureSessionRequest? {
        let retainedRequests = inputDeviceCaptureRequests.filter { $0.cameraID == cameraID }
        guard !retainedRequests.isEmpty else {
            return nil
        }
        return Self.mergedRequest(
            for: cameraID,
            requests: retainedRequests
        )
    }

    private func affectedCameraIDs(
        previousRequests: Set<WorkspaceCaptureSessionRequest>,
        nextRequests: Set<WorkspaceCaptureSessionRequest>
    ) -> Set<String> {
        Set(previousRequests.symmetricDifference(nextRequests).map(\.cameraID))
    }

    private static func mergedRequest(
        for cameraID: String,
        requests: Set<WorkspaceCaptureSessionRequest>
    ) -> WorkspaceCaptureSessionRequest {
        let baseRequest = requests.max { lhs, rhs in
            if lhs.pixelCount == rhs.pixelCount {
                return lhs.frameRate < rhs.frameRate
            }
            return lhs.pixelCount < rhs.pixelCount
        } ?? WorkspaceCaptureSessionRequest(cameraID: cameraID, width: 1, height: 1, frameRate: 1)
        return WorkspaceCaptureSessionRequest(
            cameraID: cameraID,
            width: baseRequest.width,
            height: baseRequest.height,
            frameRate: requests.map(\.frameRate).max() ?? baseRequest.frameRate
        )
    }

    private func startCapture(
        request: WorkspaceCaptureSessionRequest,
        capture: WorkspaceCaptureSessionCapture,
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        guard stateLock.withLock({ () -> Bool in
            guard !isStopping else { return false }
            pendingStartCount += 1
            return true
        }) else {
            capture.captureService.stop {
                completionHandler(.failure(CancellationError()))
            }
            return
        }
        capture.captureService.startCameraCapture(
            cameraID: request.cameraID,
            audioDeviceID: nil,
            targetWidth: request.width,
            targetHeight: request.height,
            frameRate: request.frameRate,
            capturesAudio: false,
            configurationHandler: nil,
            handler: { [weak self] sampleBuffer, kind in
                guard kind == .video else {
                    return
                }
                guard let coordinator = self else {
                    return
                }

                coordinator.stateLock.withLock {
                    coordinator.append(sampleBuffer, for: request)
                }
            },
            completionHandler: { [weak self] result in
                guard let self else {
                    completionHandler(.failure(CancellationError()))
                    return
                }
                let mustStop = self.stateLock.withLock { () -> Bool in
                    self.pendingStartCount -= 1
                    if self.isStopping {
                        self.pendingStopCount += 1
                        return true
                    }
                    return false
                }
                guard mustStop else {
                    completionHandler(result)
                    return
                }
                capture.captureService.stop {
                    self.completePendingStop()
                    completionHandler(.failure(CancellationError()))
                }
            }
        )
    }

    private func resetState(for capture: WorkspaceCaptureSessionCapture) {
        capture.latestFrame = nil
        capture.latestFrameSequence = 0
        capture.captureSessionID = UUID()
    }

    private func append(_ sampleBuffer: CMSampleBuffer, for request: WorkspaceCaptureSessionRequest) {
        guard let capture = capturesByCameraID[request.cameraID], capture.request == request else {
            return
        }
        capture.receivedSampleCount += 1
        guard let frame = makeFrame(sampleBuffer, capture: capture) else {
            capture.rejectedSampleCount += 1
            if capture.rejectedSampleCount == 1 || capture.rejectedSampleCount.isMultiple(of: 120) {
                let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                let width = imageBuffer.map(CVPixelBufferGetWidth) ?? 0
                let height = imageBuffer.map(CVPixelBufferGetHeight) ?? 0
                let pixelFormat = imageBuffer.map(CVPixelBufferGetPixelFormatType) ?? 0
                let hasIOSurface = imageBuffer.flatMap(CVPixelBufferGetIOSurface) != nil
                let presentationTime = sampleBuffer.presentationTimeStamp
                Self.logger.error(
                    "Rejected captured video sample cameraID=\(request.cameraID, privacy: .public) receivedSampleCount=\(capture.receivedSampleCount, privacy: .public) rejectedSampleCount=\(capture.rejectedSampleCount, privacy: .public) actualWidth=\(width, privacy: .public) actualHeight=\(height, privacy: .public) requestedWidth=\(request.width, privacy: .public) requestedHeight=\(request.height, privacy: .public) pixelFormat=\(pixelFormat, privacy: .public) hasIOSurface=\(hasIOSurface, privacy: .public) ptsValue=\(presentationTime.value, privacy: .public) ptsTimescale=\(presentationTime.timescale, privacy: .public) ptsFlags=\(presentationTime.flags.rawValue, privacy: .public)"
                )
            }
            return
        }
        if capture.acceptedSampleCount == 0 {
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            let width = imageBuffer.map(CVPixelBufferGetWidth) ?? 0
            let height = imageBuffer.map(CVPixelBufferGetHeight) ?? 0
            let pixelFormat = imageBuffer.map(CVPixelBufferGetPixelFormatType) ?? 0
            Self.logger.notice(
                "Accepted first captured video sample cameraID=\(request.cameraID, privacy: .public) width=\(width, privacy: .public) height=\(height, privacy: .public) pixelFormat=\(pixelFormat, privacy: .public)"
            )
        }
        capture.acceptedSampleCount += 1
        setLatestFrame(frame, for: capture)
    }

    private func makeFrame(
        _ sampleBuffer: CMSampleBuffer,
        capture: WorkspaceCaptureSessionCapture
    ) -> CapturedVideoFrame? {
        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        return CapturedVideoFrame(
            pixelBuffer: sourcePixelBuffer,
            sourcePresentationTime: sampleBuffer.presentationTimeStamp,
            captureSessionID: capture.captureSessionID,
            sequenceNumber: capture.latestFrameSequence &+ 1
        )
    }

    private func setLatestFrame(
        _ frame: CapturedVideoFrame,
        for capture: WorkspaceCaptureSessionCapture
    ) {
        capture.latestFrame = frame
        capture.latestFrameSequence = frame.sequenceNumber
        tick &+= 1
        for handler in tickHandlersByObserver.values {
            handler(tick)
        }
    }

}

/// Mutable capture state. Access is serialized by its owning coordinator's
/// `stateLock`; the instance is never exposed outside that owner.
private final class WorkspaceCaptureSessionCapture: @unchecked Sendable {
    var request: WorkspaceCaptureSessionRequest
    let captureService: any CameraCaptureStreaming
    var latestFrame: CapturedVideoFrame?
    var captureSessionID = UUID()
    var latestFrameSequence: UInt64 = 0
    var receivedSampleCount = 0
    var acceptedSampleCount = 0
    var rejectedSampleCount = 0

    init(
        request: WorkspaceCaptureSessionRequest,
        captureService: any CameraCaptureStreaming
    ) {
        self.request = request
        self.captureService = captureService
    }

    func update(request: WorkspaceCaptureSessionRequest) {
        self.request = request
    }
}

struct WorkspaceCaptureSessionRequest: Hashable, Sendable {
    var cameraID: String
    var width: Int
    var height: Int
    var frameRate: Int

    init(cameraID: String, width: Int, height: Int, frameRate: Int) {
        self.cameraID = cameraID
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.frameRate = max(frameRate, 1)
    }

    var pixelCount: Int {
        width * height
    }
}

struct CapturedVideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let sourcePresentationTime: CMTime
    let captureSessionID: UUID
    let sequenceNumber: UInt64
}
