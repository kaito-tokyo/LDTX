// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import Foundation
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXVideoComposition
import LDTXVideoRendering

public actor WorkspaceCaptureSessionCoordinator {
    private var tickContinuationsByObserver: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    private var capturesByCameraID: [String: WorkspaceCaptureSessionCapture] = [:]
    private var outputRequestsBySessionID: [Int: Set<WorkspaceCaptureSessionRequest>] = [:]
    private var persistentInputDevicePreviewRequests: Set<WorkspaceCaptureSessionRequest> = []
    private var tick: UInt64 = 0

    public init() {}

    public func synchronizePersistentInputDevicePreviewCaptures(
        cameraIDs: Set<String>
    ) async -> Set<String> {
        let nextRequests = Set(cameraIDs.map(Self.inputDevicePreviewRequest(for:)))
        let previousRequests = persistentInputDevicePreviewRequests
        persistentInputDevicePreviewRequests = nextRequests
        return await synchronizeCaptures(
            for: affectedCameraIDs(
                previousRequests: previousRequests,
                nextRequests: nextRequests
            )
        )
    }

    public func releasePersistentInputDevicePreviewCaptures() async {
        let previousRequests = persistentInputDevicePreviewRequests
        persistentInputDevicePreviewRequests = []
        _ = await synchronizeCaptures(
            for: Set(previousRequests.map(\.cameraID))
        )
    }

    func synchronizeActiveOutputCaptures(
        sessionID: Int,
        requests: Set<WorkspaceCaptureSessionRequest>
    ) async -> Set<String> {
        let previousRequests = outputRequestsBySessionID[sessionID] ?? []
        outputRequestsBySessionID[sessionID] = requests
        return await synchronizeCaptures(
            for: affectedCameraIDs(
                previousRequests: previousRequests,
                nextRequests: requests
            )
        )
    }

    func releaseActiveOutputCaptures(sessionID: Int) async {
        let previousRequests = outputRequestsBySessionID.removeValue(forKey: sessionID) ?? []
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
        for request: WorkspaceCaptureSessionRequest
    ) {
        guard let capture = capturesByCameraID[request.cameraID] else {
            return
        }
        capture.presentationTimeOffset = offset
        capture.pendingPresentationTimeOffsetAnchor = nil
    }

    func beginPreparingBackgroundRemoval(for request: WorkspaceCaptureSessionRequest) {
        guard let capture = capturesByCameraID[request.cameraID],
              capture.segmenter == nil,
              !capture.isPreparingSegmenter else {
            return
        }
        capture.isPreparingSegmenter = true
        let sourceWidth = capture.request.width
        let sourceHeight = capture.request.height
        Task.detached(priority: .utility) { [weak self] in
            let result = Result {
                try MediaPipeSelfieSegmentationModel(
                    modelURL: BackgroundRemovalModelResource.modelURL(),
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight
                )
            }
            await self?.finishPreparingBackgroundRemoval(result, for: request)
        }
    }

    func source(for request: WorkspaceCaptureSessionRequest) -> MetalVideoSource? {
        latestSource(for: request)
    }

    func latestSource(
        for request: WorkspaceCaptureSessionRequest,
        removingBackground: Bool = false
    ) -> MetalVideoSource? {
        latestFrame(
            for: request,
            removesBackground: removingBackground
        )?.source
    }

    func latestFrame(
        for request: WorkspaceCaptureSessionRequest,
        removingBackground: Bool = false
    ) -> WorkspaceCaptureSessionFrame? {
        latestFrame(
            for: request,
            removesBackground: removingBackground
        )
    }

    func latestFrame(
        for request: WorkspaceCaptureSessionRequest,
        removesBackground: Bool
    ) -> WorkspaceCaptureSessionFrame? {
        guard let capture = capturesByCameraID[request.cameraID],
              let latestFrame = capture.frameRing[capture.latestFrameIndex] else {
            return nil
        }
        let serial = capture.latestFrameSerial
        if removesBackground {
            guard capture.segmenter != nil else {
                return WorkspaceCaptureSessionFrame(
                    serial: serial,
                    source: .pixelBuffer(latestFrame.pixelBuffer),
                    sourcePresentationTime: latestFrame.presentationTime,
                    isPreparingRenderResources: capture.isPreparingSegmenter
                )
            }
            let hasReusableAlphaMask = capture.backgroundRemovalAlphaMask != nil
            if capture.backgroundRemovalInferenceGateSourceFrameSerial != serial ||
                !hasReusableAlphaMask {
                let shouldRunInference = capture.backgroundRemovalInferenceGate.shouldRunInference(
                    for: latestFrame.pixelBuffer,
                    force: !hasReusableAlphaMask
                )
                capture.backgroundRemovalInferenceGateSourceFrameSerial = serial
                if shouldRunInference {
                    if let alphaMask = makeBackgroundRemovalAlphaMask(
                        from: latestFrame.pixelBuffer,
                        capture: capture
                    ) {
                        capture.backgroundRemovalAlphaMask = alphaMask
                        capture.backgroundRemovalAlphaMaskSourceFrameSerial = serial
                    }
                }
            }
            guard let alphaMask = capture.backgroundRemovalAlphaMask else {
                return WorkspaceCaptureSessionFrame(
                    serial: serial,
                    source: .pixelBuffer(latestFrame.pixelBuffer),
                    sourcePresentationTime: latestFrame.presentationTime,
                    isPreparingRenderResources: false
                )
            }
            return WorkspaceCaptureSessionFrame(
                serial: serial,
                source: .pixelBufferWithAlphaMask(latestFrame.pixelBuffer, alphaMask),
                sourcePresentationTime: latestFrame.presentationTime,
                isPreparingRenderResources: false
            )
        }
        return WorkspaceCaptureSessionFrame(
            serial: serial,
            source: .pixelBuffer(latestFrame.pixelBuffer),
            sourcePresentationTime: latestFrame.presentationTime,
            isPreparingRenderResources: false
        )
    }

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
        outputRequestsBySessionID = [:]
        persistentInputDevicePreviewRequests = []
        for capture in capturesByCameraID.values {
            await capture.captureService.stop()
        }
        capturesByCameraID = [:]
    }

    private static func inputDevicePreviewRequest(for cameraID: String) -> WorkspaceCaptureSessionRequest {
        WorkspaceCaptureSessionRequest(
            cameraID: cameraID,
            width: 1_280,
            height: 720,
            frameRate: 30
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

        let capture = WorkspaceCaptureSessionCapture(request: request)
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
        let retainedRequests =
            persistentInputDevicePreviewRequests.filter { $0.cameraID == cameraID } +
            outputRequestsBySessionID.values.flatMap { requests in
                requests.filter { $0.cameraID == cameraID }
            }
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
        requests: [WorkspaceCaptureSessionRequest]
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

                let sample = WorkspaceCaptureSample(sampleBuffer: sampleBuffer)
                Task { [weak self, sample] in
                    await self?.enqueue(sample, for: request)
                }
            }
        )
    }

    private func resetState(for capture: WorkspaceCaptureSessionCapture) {
        capture.pendingSample = nil
        capture.isDrainingSamples = false
        capture.frameRing = Array(repeating: nil, count: capture.frameRing.count)
        capture.latestFrameIndex = 0
        capture.backgroundRemovalAlphaMask = nil
        capture.backgroundRemovalAlphaMaskSourceFrameSerial = -1
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

    private func enqueue(_ sample: WorkspaceCaptureSample, for request: WorkspaceCaptureSessionRequest) {
        guard let capture = capturesByCameraID[request.cameraID] else {
            return
        }
        capture.pendingSample = sample
        guard !capture.isDrainingSamples else {
            return
        }
        capture.isDrainingSamples = true

        Task { [weak self] in
            await self?.drainPendingSample(for: request)
        }
    }

    private func drainPendingSample(for request: WorkspaceCaptureSessionRequest) {
        guard let capture = capturesByCameraID[request.cameraID] else {
            return
        }
        guard let sample = capture.pendingSample else {
            capture.isDrainingSamples = false
            return
        }

        capture.pendingSample = nil
        append(sample, for: request)
        capture.isDrainingSamples = false
    }

    private func append(_ sample: WorkspaceCaptureSample, for request: WorkspaceCaptureSessionRequest) {
        guard let capture = capturesByCameraID[request.cameraID],
              let copiedFrame = copyFrame(sample.sampleBuffer, capture: capture) else {
            return
        }
        setLatestFrame(copiedFrame, for: capture)
    }

    private func copyFrame(
        _ sampleBuffer: CMSampleBuffer,
        capture: WorkspaceCaptureSessionCapture
    ) -> WorkspaceCaptureFrame? {
        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let destinationPixelBuffer = makeCopyDestinationPixelBuffer(for: sourcePixelBuffer, capture: capture),
              copyPixelBuffer(sourcePixelBuffer, to: destinationPixelBuffer) else {
            return nil
        }
        guard let adjustedPresentationTime = adjustedPresentationTime(
            from: sampleBuffer.presentationTimeStamp,
            capture: capture
        ) else {
            return nil
        }
        return WorkspaceCaptureFrame(
            pixelBuffer: destinationPixelBuffer,
            presentationTime: adjustedPresentationTime
        )
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

    private func makeBackgroundRemovalAlphaMask(
        from pixelBuffer: CVPixelBuffer,
        capture: WorkspaceCaptureSessionCapture
    ) -> CVPixelBuffer? {
        guard let alphaMask = makeAlphaMaskPixelBuffer(for: pixelBuffer, capture: capture),
              renderAlphaMaskPixelBuffer(pixelBuffer, to: alphaMask, capture: capture) else {
            return nil
        }
        return alphaMask
    }

    private func makeCopyDestinationPixelBuffer(
        for sourcePixelBuffer: CVPixelBuffer,
        capture: WorkspaceCaptureSessionCapture
    ) -> CVPixelBuffer? {
        let request = InputDeviceResourceManager.PixelBufferRequest(pixelBuffer: sourcePixelBuffer)
        guard request == capture.copyPixelBufferRequest else {
            return nil
        }
        return try? capture.inputDeviceResourceManager.pixelBuffer(for: capture.copyPixelBufferRequest)
    }

    private func makeAlphaMaskPixelBuffer(
        for sourcePixelBuffer: CVPixelBuffer,
        capture: WorkspaceCaptureSessionCapture
    ) -> CVPixelBuffer? {
        let request = InputDeviceResourceManager.PixelBufferRequest(
            width: CVPixelBufferGetWidth(sourcePixelBuffer),
            height: CVPixelBufferGetHeight(sourcePixelBuffer),
            pixelFormat: kCVPixelFormatType_OneComponent8
        )
        guard request == capture.alphaMaskPixelBufferRequest else {
            return nil
        }
        return try? capture.inputDeviceResourceManager.pixelBuffer(for: capture.alphaMaskPixelBufferRequest)
    }

    private func copyPixelBuffer(
        _ source: CVPixelBuffer,
        to destination: CVPixelBuffer
    ) -> Bool {
        guard CVPixelBufferGetPlaneCount(source) == CVPixelBufferGetPlaneCount(destination),
              CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(destination),
              CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(destination),
              CVPixelBufferGetPixelFormatType(source) == CVPixelBufferGetPixelFormatType(destination) else {
            return false
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount == 0 {
            guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(source),
                  let destinationBaseAddress = CVPixelBufferGetBaseAddress(destination) else {
                return false
            }
            copyRows(
                sourceBaseAddress: sourceBaseAddress,
                sourceBytesPerRow: CVPixelBufferGetBytesPerRow(source),
                destinationBaseAddress: destinationBaseAddress,
                destinationBytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                bytesPerRow: min(CVPixelBufferGetBytesPerRow(source), CVPixelBufferGetBytesPerRow(destination)),
                height: CVPixelBufferGetHeight(source)
            )
            return true
        }

        for planeIndex in 0..<planeCount {
            guard let sourceBaseAddress = CVPixelBufferGetBaseAddressOfPlane(source, planeIndex),
                  let destinationBaseAddress = CVPixelBufferGetBaseAddressOfPlane(destination, planeIndex) else {
                return false
            }
            let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, planeIndex)
            let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, planeIndex)
            copyRows(
                sourceBaseAddress: sourceBaseAddress,
                sourceBytesPerRow: sourceBytesPerRow,
                destinationBaseAddress: destinationBaseAddress,
                destinationBytesPerRow: destinationBytesPerRow,
                bytesPerRow: min(sourceBytesPerRow, destinationBytesPerRow),
                height: CVPixelBufferGetHeightOfPlane(source, planeIndex)
            )
        }
        return true
    }

    private func copyRows(
        sourceBaseAddress: UnsafeRawPointer,
        sourceBytesPerRow: Int,
        destinationBaseAddress: UnsafeMutableRawPointer,
        destinationBytesPerRow: Int,
        bytesPerRow: Int,
        height: Int
    ) {
        for y in 0..<height {
            memcpy(
                destinationBaseAddress.advanced(by: y * destinationBytesPerRow),
                sourceBaseAddress.advanced(by: y * sourceBytesPerRow),
                bytesPerRow
            )
        }
    }

    private func renderAlphaMaskPixelBuffer(
        _ source: CVPixelBuffer,
        to alphaMask: CVPixelBuffer,
        capture: WorkspaceCaptureSessionCapture
    ) -> Bool {
        guard let segmenter = capture.segmenter else {
            return false
        }
        return segmenter.renderAlphaMaskPixelBuffer(source, to: alphaMask)
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
        for request: WorkspaceCaptureSessionRequest
    ) {
        guard let capture = capturesByCameraID[request.cameraID] else {
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
    var request: WorkspaceCaptureSessionRequest
    let captureService = CameraCaptureService()
    var inputDeviceResourceManager = InputDeviceResourceManager()
    var segmenter: MediaPipeSelfieSegmentationModel?
    var isPreparingSegmenter = false
    var copyPixelBufferRequest: InputDeviceResourceManager.PixelBufferRequest
    var alphaMaskPixelBufferRequest: InputDeviceResourceManager.PixelBufferRequest
    var pendingSample: WorkspaceCaptureSample?
    var isDrainingSamples = false
    var frameRing: [WorkspaceCaptureFrame?] = Array(repeating: nil, count: 3)
    var latestFrameIndex = 0
    var latestFrameSerial = 0
    var backgroundRemovalAlphaMask: CVPixelBuffer?
    var backgroundRemovalAlphaMaskSourceFrameSerial = -1
    var backgroundRemovalInferenceGateSourceFrameSerial = -1
    let backgroundRemovalInferenceGate = BackgroundRemovalInferenceGate()
    var presentationTimeOffset: CMTime = .zero
    var pendingPresentationTimeOffsetAnchor: CMTime?
    var lastAdjustedPresentationTime: CMTime?

    init(request: WorkspaceCaptureSessionRequest) {
        self.request = request
        copyPixelBufferRequest = InputDeviceResourceManager.PixelBufferRequest(
            width: request.width,
            height: request.height,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        alphaMaskPixelBufferRequest = InputDeviceResourceManager.PixelBufferRequest(
            width: request.width,
            height: request.height,
            pixelFormat: kCVPixelFormatType_OneComponent8
        )
    }

    func update(request: WorkspaceCaptureSessionRequest) {
        self.request = request
        inputDeviceResourceManager = InputDeviceResourceManager()
        copyPixelBufferRequest = InputDeviceResourceManager.PixelBufferRequest(
            width: request.width,
            height: request.height,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        alphaMaskPixelBufferRequest = InputDeviceResourceManager.PixelBufferRequest(
            width: request.width,
            height: request.height,
            pixelFormat: kCVPixelFormatType_OneComponent8
        )
        segmenter = nil
        isPreparingSegmenter = false
    }
}

private final class InputDeviceResourceManager: @unchecked Sendable {
    struct PixelBufferRequest: Hashable, Sendable {
        var width: Int
        var height: Int
        var pixelFormat: OSType

        init(pixelBuffer: CVPixelBuffer) {
            self.init(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer)
            )
        }

        init(width: Int, height: Int, pixelFormat: OSType) {
            self.width = max(width, 1)
            self.height = max(height, 1)
            self.pixelFormat = pixelFormat
        }
    }

    private static let minimumBufferCount = 3

    private final class PixelBufferRing {
        private var pixelBuffers: [CVPixelBuffer]
        private var nextIndex = 0

        init(pixelBuffers: [CVPixelBuffer]) {
            self.pixelBuffers = pixelBuffers
        }

        func nextPixelBuffer() -> CVPixelBuffer {
            let pixelBuffer = pixelBuffers[nextIndex]
            nextIndex = (nextIndex + 1) % pixelBuffers.count
            return pixelBuffer
        }
    }

    private var pixelBufferRings: [PixelBufferRequest: PixelBufferRing] = [:]

    func pixelBuffer(for request: PixelBufferRequest) throws -> CVPixelBuffer {
        let ring = try pixelBufferRing(for: request)
        return ring.nextPixelBuffer()
    }

    private func pixelBufferRing(for request: PixelBufferRequest) throws -> PixelBufferRing {
        if let pixelBufferRing = pixelBufferRings[request] {
            return pixelBufferRing
        }

        let pixelBufferRing = try Self.makePixelBufferRing(for: request)
        pixelBufferRings[request] = pixelBufferRing
        return pixelBufferRing
    }

    private static func makePixelBufferRing(for request: PixelBufferRequest) throws -> PixelBufferRing {
        let pixelBufferPool = try makePixelBufferPool(for: request)
        var pixelBuffers: [CVPixelBuffer] = []
        pixelBuffers.reserveCapacity(minimumBufferCount)

        for _ in 0..<minimumBufferCount {
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw VideoCompositorError.outputPixelBufferCreationFailed(status)
            }
            pixelBuffers.append(pixelBuffer)
        }

        return PixelBufferRing(pixelBuffers: pixelBuffers)
    }

    private static func makePixelBufferPool(for request: PixelBufferRequest) throws -> CVPixelBufferPool {
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: minimumBufferCount
        ]
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: request.pixelFormat,
            kCVPixelBufferWidthKey as String: request.width,
            kCVPixelBufferHeightKey as String: request.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var pixelBufferPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pixelBufferPool
        )
        guard status == kCVReturnSuccess, let pixelBufferPool else {
            throw VideoCompositorError.pixelBufferPoolCreationFailed(status)
        }
        return pixelBufferPool
    }
}

private struct WorkspaceCaptureSample: @unchecked Sendable {
    var sampleBuffer: CMSampleBuffer
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
}

private final class BackgroundRemovalInferenceGate {
    private static let lumaSubsamplingStride = 4
    private static let motionIntensityThreshold = 0.0001

    private var previousWidth = 0
    private var previousHeight = 0
    private var previousSamples: [UInt8] = []
    private var currentSamples: [UInt8] = []

    func shouldRunInference(for pixelBuffer: CVPixelBuffer, force: Bool = false) -> Bool {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            reset()
            return true
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        guard let lumaBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            reset()
            return true
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = lumaBaseAddress.assumingMemoryBound(to: UInt8.self)
        let subsamplingStride = Self.lumaSubsamplingStride
        let sampleCount = ((width + subsamplingStride - 1) / subsamplingStride) *
            ((height + subsamplingStride - 1) / subsamplingStride)

        currentSamples.removeAll(keepingCapacity: true)
        currentSamples.reserveCapacity(sampleCount)
        var squaredDifferenceSum = 0.0
        let canCompare = previousWidth == width &&
            previousHeight == height &&
            previousSamples.count == sampleCount
        var sampleIndex = 0

        for y in stride(from: 0, to: height, by: subsamplingStride) {
            let rowOffset = y * bytesPerRow
            for x in stride(from: 0, to: width, by: subsamplingStride) {
                let sample = luma[rowOffset + x]
                currentSamples.append(sample)
                if canCompare {
                    let difference = Double(Int(sample) - Int(previousSamples[sampleIndex])) / 255.0
                    squaredDifferenceSum += difference * difference
                    sampleIndex += 1
                }
            }
        }

        swap(&previousSamples, &currentSamples)
        previousWidth = width
        previousHeight = height

        guard canCompare, !force else {
            return true
        }
        let motionIntensity = squaredDifferenceSum / Double(sampleCount)
        return motionIntensity >= Self.motionIntensityThreshold
    }

    func reset() {
        previousWidth = 0
        previousHeight = 0
        previousSamples.removeAll(keepingCapacity: true)
        currentSamples.removeAll(keepingCapacity: true)
    }
}
