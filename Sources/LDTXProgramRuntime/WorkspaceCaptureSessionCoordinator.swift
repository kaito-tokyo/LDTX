// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import Foundation
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXProgram
import LDTXVideoComposition
import LDTXVideoRendering
import OSLog
#if canImport(Metal)
import Metal
#endif

public final class WorkspaceCaptureSessionCoordinator: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "tokyo.kaito.ldtx",
        category: "WorkspaceCaptureSessionCoordinator"
    )
    private static let signpostLog = OSLog(
        subsystem: "tokyo.kaito.ldtx",
        category: "PointsOfInterest"
    )

    #if canImport(Metal)
    public let metalDevice: MTLDevice?
    private let captureTextureCache: CVMetalTextureCache?
    #endif

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

    #if canImport(Metal)
    public init(
        metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice(),
        captureServiceFactory: @escaping @Sendable () -> any CameraCaptureStreaming = {
            CameraCaptureService()
        }
    ) {
        self.metalDevice = metalDevice
        self.captureServiceFactory = captureServiceFactory
        if let metalDevice {
            var textureCache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &textureCache)
            captureTextureCache = textureCache
        } else {
            captureTextureCache = nil
        }
    }
    #else
    public init(
        captureServiceFactory: @escaping @Sendable () -> any CameraCaptureStreaming = {
            CameraCaptureService()
        }
    ) {
        self.captureServiceFactory = captureServiceFactory
    }
    #endif

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
        let request = stateLock.withLock { () -> WorkspaceCaptureSessionRequest in
            let request = capture.request
            preparePresentationTimeOffsetForRestart(
                request: request,
                capture: capture
            )
            return request
        }
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

    func setPresentationTimeOffset(
        _ offset: CMTime,
        forCameraID cameraID: String
    ) {
        stateLock.withLock {
            guard let capture = capturesByCameraID[cameraID] else {
                return
            }
            capture.presentationTimeOffset = offset
            capture.pendingPresentationTimeOffsetAnchor = nil
        }
    }

    func beginPreparingBackgroundRemoval(forCameraID cameraID: String) {
        let dimensions: (width: Int, height: Int)? = stateLock.withLock {
            guard let capture = capturesByCameraID[cameraID],
                  capture.segmenter == nil,
                  !capture.isPreparingSegmenter else {
                return nil
            }
            capture.isPreparingSegmenter = true
            return (capture.request.width, capture.request.height)
        }
        guard let dimensions else {
            return
        }
        let sourceWidth = dimensions.width
        let sourceHeight = dimensions.height
        #if canImport(Metal)
        let metalDevice = metalDevice
        #endif
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let signpostID = OSSignpostID(log: Self.signpostLog)
            os_signpost(
                .begin,
                log: Self.signpostLog,
                name: "Background Removal Prepare",
                signpostID: signpostID,
                "sourceWidth=%{public}d sourceHeight=%{public}d",
                sourceWidth,
                sourceHeight
            )
            defer {
                os_signpost(
                    .end,
                    log: Self.signpostLog,
                    name: "Background Removal Prepare",
                    signpostID: signpostID
                )
            }
            let result = Result {
                #if canImport(Metal)
                try MediaPipeSelfieSegmentationModel(
                    modelURL: BackgroundRemovalModelResource.modelURL(),
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    metalDevice: metalDevice
                )
                #else
                try MediaPipeSelfieSegmentationModel(
                    modelURL: BackgroundRemovalModelResource.modelURL(),
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight
                )
                #endif
            }
            self?.stateLock.withLock {
                self?.finishPreparingBackgroundRemoval(result, forCameraID: cameraID)
            }
        }
    }

    func latestSource(
        forCameraID cameraID: String,
        removingBackground: Bool = false
    ) -> MetalVideoSource? {
        latestFrame(
            forCameraID: cameraID,
            removesBackground: removingBackground
        )?.source
    }

    public func latestPixelBuffer(forCameraID cameraID: String) -> CVPixelBuffer? {
        stateLock.withLock {
            guard let capture = capturesByCameraID[cameraID] else { return nil }
            return capture.frameRing[capture.latestFrameIndex]?.pixelBuffer
        }
    }

    func latestFrame(
        forCameraID cameraID: String,
        removingBackground: Bool = false
    ) -> WorkspaceCaptureSessionFrame? {
        latestFrame(
            forCameraID: cameraID,
            removesBackground: removingBackground
        )
    }

    func latestFrame(
        forCameraID cameraID: String,
        removesBackground: Bool
    ) -> WorkspaceCaptureSessionFrame? {
        stateLock.withLock {
            latestFrameLocked(
                forCameraID: cameraID,
                removesBackground: removesBackground
            )
        }
    }

    private func latestFrameLocked(
        forCameraID cameraID: String,
        removesBackground: Bool
    ) -> WorkspaceCaptureSessionFrame? {
        guard let capture = capturesByCameraID[cameraID],
              var latestFrame = capture.frameRing[capture.latestFrameIndex] else {
            return nil
        }
        let serial = capture.latestFrameSerial
        if removesBackground {
            let signpostID = OSSignpostID(log: Self.signpostLog)
            os_signpost(
                .begin,
                log: Self.signpostLog,
                name: "Background Removal Frame",
                signpostID: signpostID,
                "serial=%{public}d",
                serial
            )
            defer {
                os_signpost(
                    .end,
                    log: Self.signpostLog,
                    name: "Background Removal Frame",
                    signpostID: signpostID
                )
            }
            guard capture.segmenter != nil else {
                guard let source = source(for: &latestFrame) else {
                    return nil
                }
                capture.frameRing[capture.latestFrameIndex] = latestFrame
                return WorkspaceCaptureSessionFrame(
                    serial: serial,
                    source: source,
                    sourcePresentationTime: latestFrame.presentationTime,
                    isPreparingRenderResources: capture.isPreparingSegmenter
                )
            }
            let hasReusableRawMask = capture.backgroundRemovalRawMaskTexture != nil
            if capture.backgroundRemovalInferenceGateSourceFrameSerial != serial ||
                !hasReusableRawMask {
                let inputTextures = inputTextures(for: &latestFrame)
                let shouldRunInference = capture.backgroundRemovalInferenceGate.shouldRunInference(
                    lumaTexture: inputTextures?.lumaTexture,
                    force: !hasReusableRawMask
                )
                os_signpost(
                    .event,
                    log: Self.signpostLog,
                    name: "Background Removal Inference Decision",
                    "run=%{public}d force=%{public}d reusedMask=%{public}d",
                    shouldRunInference ? 1 : 0,
                    hasReusableRawMask ? 0 : 1,
                    hasReusableRawMask ? 1 : 0
                )
                capture.backgroundRemovalInferenceGateSourceFrameSerial = serial
                if shouldRunInference {
                    if let rawMaskTexture = makeBackgroundRemovalRawMaskTexture(
                        from: &latestFrame,
                        capture: capture
                    ) {
                        capture.backgroundRemovalRawMaskTexture = rawMaskTexture
                        capture.backgroundRemovalRawMaskSourceFrameSerial = serial
                    }
                }
            }
            guard let rawMaskTexture = capture.backgroundRemovalRawMaskTexture else {
                return nil
            }
            guard let source = source(for: &latestFrame, rawMaskTexture: rawMaskTexture) else {
                return nil
            }
            capture.frameRing[capture.latestFrameIndex] = latestFrame
            return WorkspaceCaptureSessionFrame(
                serial: serial,
                source: source,
                sourcePresentationTime: latestFrame.presentationTime,
                isPreparingRenderResources: false
            )
        }
        guard let source = source(for: &latestFrame) else {
            return nil
        }
        capture.frameRing[capture.latestFrameIndex] = latestFrame
        return WorkspaceCaptureSessionFrame(
            serial: serial,
            source: source,
            sourcePresentationTime: latestFrame.presentationTime,
            isPreparingRenderResources: false
        )
    }

    private func source(
        for frame: inout WorkspaceCaptureFrame,
        rawMaskTexture: MTLTexture? = nil
    ) -> MetalVideoSource? {
        #if canImport(Metal)
        if let rawMaskTexture,
           rawMaskTexture.pixelFormat != .r16Float {
            return nil
        }
        guard let inputTextures = inputTextures(for: &frame) else {
            return nil
        }
        return inputTextures.source(
            pixelBuffer: frame.pixelBuffer,
            rawMaskTexture: rawMaskTexture
        )
        #else
        _ = rawMaskTexture
        return nil
        #endif
    }

    #if canImport(Metal)
    private func inputTextures(
        for frame: inout WorkspaceCaptureFrame
    ) -> WorkspaceCaptureFrameInputTextures? {
        if let inputTextures = frame.inputTextures {
            return inputTextures
        }
        guard let captureTextureCache else {
            return nil
        }
        do {
            let inputTextures = try WorkspaceCaptureFrameInputTextures(
                pixelBuffer: frame.pixelBuffer,
                textureCache: captureTextureCache
            )
            frame.inputTextures = inputTextures
            return inputTextures
        } catch {
            return nil
        }
    }
    #endif

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
            stateLock.withLock {
                preparePresentationTimeOffsetForRestart(
                    request: request,
                    capture: capture
                )
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

        #if canImport(Metal)
        let capture = WorkspaceCaptureSessionCapture(
            request: request,
            metalDevice: metalDevice,
            captureService: captureServiceFactory()
        )
        #else
        let capture = WorkspaceCaptureSessionCapture(
            request: request,
            captureService: captureServiceFactory()
        )
        #endif
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
        capture.frameRing = Array(repeating: nil, count: capture.frameRing.count)
        capture.latestFrameIndex = 0
        #if canImport(Metal)
        capture.backgroundRemovalRawMaskTexture = nil
        capture.backgroundRemovalRawMaskTextureRing = []
        capture.nextBackgroundRemovalRawMaskTextureIndex = 0
        #endif
        capture.backgroundRemovalRawMaskSourceFrameSerial = -1
        capture.backgroundRemovalInferenceGateSourceFrameSerial = -1
        capture.backgroundRemovalInferenceGate.reset()
    }

    private func preparePresentationTimeOffsetForRestart(
        request: WorkspaceCaptureSessionRequest,
        capture: WorkspaceCaptureSessionCapture
    ) {
        guard let lastAdjustedPresentationTime = capture.lastAdjustedPresentationTime else {
            return
        }
        capture.pendingPresentationTimeOffsetAnchor = CMTimeAdd(
            lastAdjustedPresentationTime,
            request.frameDuration
        )
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
    ) -> WorkspaceCaptureFrame? {
        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              Self.isSupportedCapturedPixelBuffer(sourcePixelBuffer, capture: capture) else {
            return nil
        }
        guard let adjustedPresentationTime = adjustedPresentationTime(
            from: sampleBuffer.presentationTimeStamp,
            capture: capture
        ) else {
            return nil
        }
        return WorkspaceCaptureFrame(
            pixelBuffer: sourcePixelBuffer,
            presentationTime: adjustedPresentationTime
        )
    }

    private static func isSupportedCapturedPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        capture: WorkspaceCaptureSessionCapture
    ) -> Bool {
        guard CVPixelBufferGetWidth(pixelBuffer) == capture.request.width,
              CVPixelBufferGetHeight(pixelBuffer) == capture.request.height,
              CVPixelBufferGetIOSurface(pixelBuffer) != nil else {
            return false
        }
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return true
        default:
            return false
        }
    }

    private func adjustedPresentationTime(
        from sourcePresentationTime: CMTime,
        capture: WorkspaceCaptureSessionCapture
    ) -> CMTime? {
        if let pendingAnchor = capture.pendingPresentationTimeOffsetAnchor {
            capture.presentationTimeOffset = CMTimeSubtract(
                pendingAnchor,
                sourcePresentationTime
            )
            capture.pendingPresentationTimeOffsetAnchor = nil
        }

        let adjustedPresentationTime = CMTimeAdd(
            sourcePresentationTime,
            capture.presentationTimeOffset
        )
        if let lastAdjustedPresentationTime = capture.lastAdjustedPresentationTime,
           CMTimeCompare(adjustedPresentationTime, lastAdjustedPresentationTime) <= 0 {
            return nil
        }

        capture.lastAdjustedPresentationTime = adjustedPresentationTime
        return adjustedPresentationTime
    }

    private func makeBackgroundRemovalRawMaskTexture(
        from frame: inout WorkspaceCaptureFrame,
        capture: WorkspaceCaptureSessionCapture
    ) -> MTLTexture? {
        guard let inputTextures = inputTextures(for: &frame) else {
            return nil
        }
        guard let rawMaskTexture = nextRawMaskTexture(capture: capture),
              renderRawMaskTexture(
                  frame.pixelBuffer,
                  inputTextures: inputTextures,
                  to: rawMaskTexture,
                  capture: capture
              ) else {
            return nil
        }
        return rawMaskTexture
    }

    private func nextRawMaskTexture(
        capture: WorkspaceCaptureSessionCapture
    ) -> MTLTexture? {
        #if canImport(Metal)
        guard ensureRawMaskTextureRing(capture: capture),
              !capture.backgroundRemovalRawMaskTextureRing.isEmpty else {
            return nil
        }
        let index = capture.nextBackgroundRemovalRawMaskTextureIndex %
            capture.backgroundRemovalRawMaskTextureRing.count
        capture.nextBackgroundRemovalRawMaskTextureIndex = (index + 1) %
            capture.backgroundRemovalRawMaskTextureRing.count
        return capture.backgroundRemovalRawMaskTextureRing[index]
        #else
        return nil
        #endif
    }

    #if canImport(Metal)
    private func ensureRawMaskTextureRing(
        capture: WorkspaceCaptureSessionCapture
    ) -> Bool {
        if capture.backgroundRemovalRawMaskTextureRing.count == WorkspaceCaptureSessionCapture.rawMaskTextureRingCount {
            return true
        }
        guard let metalDevice else {
            return false
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: MediaPipeSelfieSegmentationModel.rawMaskWidth,
            height: MediaPipeSelfieSegmentationModel.rawMaskHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        var textures: [MTLTexture] = []
        textures.reserveCapacity(WorkspaceCaptureSessionCapture.rawMaskTextureRingCount)
        for _ in 0..<WorkspaceCaptureSessionCapture.rawMaskTextureRingCount {
            guard let texture = metalDevice.makeTexture(descriptor: descriptor) else {
                return false
            }
            textures.append(texture)
        }
        capture.backgroundRemovalRawMaskTextureRing = textures
        capture.nextBackgroundRemovalRawMaskTextureIndex = 0
        return true
    }
    #endif

    private func renderRawMaskTexture(
        _ source: CVPixelBuffer,
        inputTextures: WorkspaceCaptureFrameInputTextures,
        to rawMaskTexture: MTLTexture,
        capture: WorkspaceCaptureSessionCapture
    ) -> Bool {
        guard let segmenter = capture.segmenter else {
            return false
        }
        guard let lumaTexture = inputTextures.lumaTexture,
              let chromaTexture = inputTextures.chromaTexture else {
            return false
        }
        return segmenter.renderRawMaskTexture(
            source,
            lumaTexture: lumaTexture,
            chromaTexture: chromaTexture,
            to: rawMaskTexture
        )
    }

    private func setLatestFrame(
        _ frame: WorkspaceCaptureFrame,
        for capture: WorkspaceCaptureSessionCapture
    ) {
        capture.latestFrameIndex = (capture.latestFrameIndex + 1) % capture.frameRing.count
        capture.frameRing[capture.latestFrameIndex] = frame
        capture.latestFrameSerial &+= 1
        tick &+= 1
        for handler in tickHandlersByObserver.values {
            handler(tick)
        }
    }

    private func finishPreparingBackgroundRemoval(
        _ result: Result<MediaPipeSelfieSegmentationModel, any Error>,
        forCameraID cameraID: String
    ) {
        guard let capture = capturesByCameraID[cameraID] else {
            return
        }
        capture.isPreparingSegmenter = false
        if case let .success(segmenter) = result {
            capture.segmenter = segmenter
        }
        tick &+= 1
        for handler in tickHandlersByObserver.values {
            handler(tick)
        }
    }
}

/// Mutable capture state. Access is serialized by its owning coordinator's
/// `stateLock`; the instance is never exposed outside that owner.
private final class WorkspaceCaptureSessionCapture: @unchecked Sendable {
    static let rawMaskTextureRingCount = 3

    var request: WorkspaceCaptureSessionRequest
    let captureService: any CameraCaptureStreaming
    var segmenter: MediaPipeSelfieSegmentationModel?
    var isPreparingSegmenter = false
    var frameRing: [WorkspaceCaptureFrame?] = Array(repeating: nil, count: 3)
    var latestFrameIndex = 0
    var latestFrameSerial = 0
    var receivedSampleCount = 0
    var acceptedSampleCount = 0
    var rejectedSampleCount = 0
    #if canImport(Metal)
    var backgroundRemovalRawMaskTexture: MTLTexture?
    var backgroundRemovalRawMaskTextureRing: [MTLTexture] = []
    var nextBackgroundRemovalRawMaskTextureIndex = 0
    #endif
    var backgroundRemovalRawMaskSourceFrameSerial = -1
    var backgroundRemovalInferenceGateSourceFrameSerial = -1
    let backgroundRemovalInferenceGate: BackgroundRemovalInferenceGate
    var presentationTimeOffset: CMTime = .zero
    var pendingPresentationTimeOffsetAnchor: CMTime?
    var lastAdjustedPresentationTime: CMTime?

    #if canImport(Metal)
    init(
        request: WorkspaceCaptureSessionRequest,
        metalDevice: MTLDevice?,
        captureService: any CameraCaptureStreaming
    ) {
        self.request = request
        self.captureService = captureService
        backgroundRemovalInferenceGate = BackgroundRemovalInferenceGate(metalDevice: metalDevice)
    }
    #else
    init(
        request: WorkspaceCaptureSessionRequest,
        captureService: any CameraCaptureStreaming
    ) {
        self.request = request
        self.captureService = captureService
        backgroundRemovalInferenceGate = BackgroundRemovalInferenceGate()
    }
    #endif

    func update(request: WorkspaceCaptureSessionRequest) {
        self.request = request
        segmenter = nil
        isPreparingSegmenter = false
        #if canImport(Metal)
        backgroundRemovalRawMaskTexture = nil
        backgroundRemovalRawMaskTextureRing = []
        nextBackgroundRemovalRawMaskTextureIndex = 0
        #endif
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

    var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(frameRate))
    }

    var pixelCount: Int {
        width * height
    }
}

struct WorkspaceCaptureSessionFrame {
    var serial: Int
    var source: MetalVideoSource
    var sourcePresentationTime: CMTime
    var isPreparingRenderResources: Bool = false
}

private struct WorkspaceCaptureFrame {
    var pixelBuffer: CVPixelBuffer
    var presentationTime: CMTime
    #if canImport(Metal)
    var inputTextures: WorkspaceCaptureFrameInputTextures?
    #endif
}

#if canImport(Metal)
private struct WorkspaceCaptureFrameInputTextures {
    let lumaMetalTexture: CVMetalTexture
    let chromaMetalTexture: CVMetalTexture

    init(
        pixelBuffer: CVPixelBuffer,
        textureCache: CVMetalTextureCache
    ) throws {
        lumaMetalTexture = try Self.makeTexture(
            pixelBuffer,
            textureCache: textureCache,
            pixelFormat: .r8Uint,
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            planeIndex: 0
        )
        chromaMetalTexture = try Self.makeTexture(
            pixelBuffer,
            textureCache: textureCache,
            pixelFormat: .rg8Uint,
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
            height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
            planeIndex: 1
        )
    }

    var lumaTexture: MTLTexture? {
        CVMetalTextureGetTexture(lumaMetalTexture)
    }

    var chromaTexture: MTLTexture? {
        CVMetalTextureGetTexture(chromaMetalTexture)
    }

    func source(
        pixelBuffer: CVPixelBuffer,
        rawMaskTexture: MTLTexture?
    ) -> MetalVideoSource {
        .nv12Textures(
            pixelBuffer: pixelBuffer,
            lumaMetalTexture: lumaMetalTexture,
            chromaMetalTexture: chromaMetalTexture,
            alphaTexture: rawMaskTexture,
            alphaMaskKind: rawMaskTexture == nil ? nil : .rawFloat16
        )
    }

    private static func makeTexture(
        _ pixelBuffer: CVPixelBuffer,
        textureCache: CVMetalTextureCache,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        planeIndex: Int
    ) throws -> CVMetalTexture {
        var metalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &metalTexture
        )
        guard status == kCVReturnSuccess, let metalTexture else {
            throw VideoCompositorError.textureCreationFailed(status)
        }
        return metalTexture
    }
}
#endif
