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

public actor WorkspaceCaptureSessionCoordinator {
    private static let signpostLog = OSLog(
        subsystem: "tokyo.kaito.ldtx",
        category: "PointsOfInterest"
    )

    #if canImport(Metal)
    public nonisolated let metalDevice: MTLDevice?
    private let captureTextureCache: CVMetalTextureCache?
    #endif

    private var tickContinuationsByObserver: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    private var capturesByCameraID: [String: WorkspaceCaptureSessionCapture] = [:]
    private var inputDeviceCaptureRequests: Set<WorkspaceCaptureSessionRequest> = []
    private var tick: UInt64 = 0

    #if canImport(Metal)
    public init(metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.metalDevice = metalDevice
        if let metalDevice {
            var textureCache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &textureCache)
            captureTextureCache = textureCache
        } else {
            captureTextureCache = nil
        }
    }
    #else
    public init() {}
    #endif

    public func synchronizeInputDeviceCaptures(
        inputDevices: [ProgramInputDeviceRecord],
        availableCameraIDs: Set<String>,
        canvasWidth: Int,
        canvasHeight: Int,
        frameRate: Int
    ) async -> Set<String> {
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
        let previousRequests = inputDeviceCaptureRequests
        inputDeviceCaptureRequests = nextRequests
        return await synchronizeCaptures(
            for: affectedCameraIDs(
                previousRequests: previousRequests,
                nextRequests: nextRequests
            )
        )
    }

    public func releaseInputDeviceCaptures() async {
        let previousRequests = inputDeviceCaptureRequests
        inputDeviceCaptureRequests = []
        _ = await synchronizeCaptures(
            for: Set(previousRequests.map(\.cameraID))
        )
    }

    public func restartAllCaptureSessions() async -> Set<String> {
        let captures = Array(capturesByCameraID.values)
        var failedCameraIDs: Set<String> = []

        for capture in captures {
            let request = capture.request
            preparePresentationTimeOffsetForRestart(
                request: request,
                capture: capture
            )
            await capture.captureService.stop()
            resetState(for: capture)
            do {
                try await startCapture(request: request, capture: capture)
            } catch {
                failedCameraIDs.insert(request.cameraID)
            }
        }

        return failedCameraIDs
    }

    func setPresentationTimeOffset(
        _ offset: CMTime,
        forCameraID cameraID: String
    ) {
        guard let capture = capturesByCameraID[cameraID] else {
            return
        }
        capture.presentationTimeOffset = offset
        capture.pendingPresentationTimeOffsetAnchor = nil
    }

    func beginPreparingBackgroundRemoval(forCameraID cameraID: String) {
        guard let capture = capturesByCameraID[cameraID],
              capture.segmenter == nil,
              !capture.isPreparingSegmenter else {
            return
        }
        capture.isPreparingSegmenter = true
        let sourceWidth = capture.request.width
        let sourceHeight = capture.request.height
        #if canImport(Metal)
        let metalDevice = metalDevice
        #endif
        Task.detached(priority: .utility) { [weak self] in
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
            await self?.finishPreparingBackgroundRemoval(result, forCameraID: cameraID)
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

    func tickStream() -> AsyncStream<UInt64> {
        let observerID = UUID()
        return AsyncStream { continuation in
            tickContinuationsByObserver[observerID] = continuation
            continuation.yield(tick)
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeTickObserver(observerID)
                }
            }
        }
    }

    func stop() async {
        inputDeviceCaptureRequests = []
        for capture in capturesByCameraID.values {
            await capture.captureService.stop()
        }
        capturesByCameraID = [:]
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

    private func stopCapture(cameraID: String) async {
        guard let capture = capturesByCameraID.removeValue(forKey: cameraID) else {
            return
        }
        await capture.captureService.stop()
    }

    private func synchronizeCaptures(
        for cameraIDs: Set<String>
    ) async -> Set<String> {
        var failedCameraIDs: Set<String> = []
        for cameraID in cameraIDs {
            do {
                try await synchronizeCapture(cameraID: cameraID)
            } catch {
                failedCameraIDs.insert(cameraID)
            }
        }
        return failedCameraIDs
    }

    private func synchronizeCapture(cameraID: String) async throws {
        guard let request = effectiveRequest(for: cameraID) else {
            await stopCapture(cameraID: cameraID)
            return
        }

        if let capture = capturesByCameraID[cameraID] {
            guard capture.request != request else {
                return
            }
            preparePresentationTimeOffsetForRestart(
                request: request,
                capture: capture
            )
            await capture.captureService.stop()
            resetState(for: capture)
            capture.update(request: request)
            do {
                try await startCapture(request: request, capture: capture)
            } catch {
                capturesByCameraID.removeValue(forKey: cameraID)
                throw error
            }
            return
        }

        #if canImport(Metal)
        let capture = WorkspaceCaptureSessionCapture(
            request: request,
            metalDevice: metalDevice
        )
        #else
        let capture = WorkspaceCaptureSessionCapture(request: request)
        #endif
        capturesByCameraID[cameraID] = capture
        do {
            try await startCapture(request: request, capture: capture)
        } catch {
            if capturesByCameraID[cameraID] === capture {
                capturesByCameraID.removeValue(forKey: cameraID)
            }
            throw error
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
        capture: WorkspaceCaptureSessionCapture
    ) async throws {
        let sampleCoalescer = capture.sampleCoalescer
        try await capture.captureService.startCameraCapture(
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

                let sample = WorkspaceCaptureSample(sampleBuffer: sampleBuffer)
                sampleCoalescer.enqueue(sample) { coalescer in
                    Task {
                        await coordinator.drainPendingSample(for: request, coalescer: coalescer)
                    }
                }
            }
        )
    }

    private func resetState(for capture: WorkspaceCaptureSessionCapture) {
        capture.sampleCoalescer.reset()
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

    private func drainPendingSample(
        for request: WorkspaceCaptureSessionRequest,
        coalescer: WorkspaceCaptureSampleCoalescer
    ) {
        guard let sample = coalescer.takePendingSample() else {
            return
        }
        append(sample, for: request)
    }

    private func append(_ sample: WorkspaceCaptureSample, for request: WorkspaceCaptureSessionRequest) {
        guard let capture = capturesByCameraID[request.cameraID],
              capture.request == request,
              let frame = makeFrame(sample.sampleBuffer, capture: capture) else {
            return
        }
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
        for continuation in tickContinuationsByObserver.values {
            continuation.yield(tick)
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
        for continuation in tickContinuationsByObserver.values {
            continuation.yield(tick)
        }
    }

    private func removeTickObserver(_ observerID: UUID) {
        tickContinuationsByObserver.removeValue(forKey: observerID)
    }
}

private final class WorkspaceCaptureSessionCapture {
    static let rawMaskTextureRingCount = 3

    var request: WorkspaceCaptureSessionRequest
    let captureService = CameraCaptureService()
    let sampleCoalescer = WorkspaceCaptureSampleCoalescer()
    var segmenter: MediaPipeSelfieSegmentationModel?
    var isPreparingSegmenter = false
    var frameRing: [WorkspaceCaptureFrame?] = Array(repeating: nil, count: 3)
    var latestFrameIndex = 0
    var latestFrameSerial = 0
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
        metalDevice: MTLDevice?
    ) {
        self.request = request
        backgroundRemovalInferenceGate = BackgroundRemovalInferenceGate(metalDevice: metalDevice)
    }
    #else
    init(request: WorkspaceCaptureSessionRequest) {
        self.request = request
        backgroundRemovalInferenceGate = BackgroundRemovalInferenceGate()
    }
    #endif

    func update(request: WorkspaceCaptureSessionRequest) {
        self.request = request
        sampleCoalescer.reset()
        segmenter = nil
        isPreparingSegmenter = false
        #if canImport(Metal)
        backgroundRemovalRawMaskTexture = nil
        backgroundRemovalRawMaskTextureRing = []
        nextBackgroundRemovalRawMaskTextureIndex = 0
        #endif
    }
}

private struct WorkspaceCaptureSample: @unchecked Sendable {
    var sampleBuffer: CMSampleBuffer
}

private final class WorkspaceCaptureSampleCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingSample: WorkspaceCaptureSample?
    private var isDrainScheduled = false

    func enqueue(
        _ sample: WorkspaceCaptureSample,
        scheduleDrain: @escaping @Sendable (WorkspaceCaptureSampleCoalescer) -> Void
    ) {
        let shouldScheduleDrain = lock.withLock { () -> Bool in
            pendingSample = sample
            guard !isDrainScheduled else {
                return false
            }
            isDrainScheduled = true
            return true
        }
        if shouldScheduleDrain {
            scheduleDrain(self)
        }
    }

    func takePendingSample() -> WorkspaceCaptureSample? {
        lock.withLock {
            let sample = pendingSample
            pendingSample = nil
            isDrainScheduled = false
            return sample
        }
    }

    func reset() {
        lock.withLock {
            pendingSample = nil
            isDrainScheduled = false
        }
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

struct WorkspaceCaptureSessionFrame: Sendable {
    var serial: Int
    var source: MetalVideoSource
    var sourcePresentationTime: CMTime
    var isPreparingRenderResources: Bool = false
}

private struct WorkspaceCaptureFrame: @unchecked Sendable {
    var pixelBuffer: CVPixelBuffer
    var presentationTime: CMTime
    #if canImport(Metal)
    var inputTextures: WorkspaceCaptureFrameInputTextures?
    #endif
}

#if canImport(Metal)
private struct WorkspaceCaptureFrameInputTextures: @unchecked Sendable {
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
