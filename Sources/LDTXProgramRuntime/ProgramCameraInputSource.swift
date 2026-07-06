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

public actor ProgramCameraInputSource {
    private var tickContinuationsByObserver: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    private var capturesByRequest: [ProgramCameraInputRequest: ProgramCameraInputCapture] = [:]
    private let inputDeviceResourceManager = InputDeviceResourceManager()
    private var tick: UInt64 = 0

    public init() {}

    func retain(request: ProgramCameraInputRequest) async throws {
        if let capture = capturesByRequest[request] {
            capture.referenceCount += 1
            return
        }

        let capture = ProgramCameraInputCapture(request: request)
        capture.referenceCount = 1
        capturesByRequest[request] = capture
        try await startCapture(request: request, capture: capture)
    }

    func beginPreparingBackgroundRemoval(for request: ProgramCameraInputRequest) {
        guard let capture = capturesByRequest[request],
              capture.segmenter == nil,
              !capture.isPreparingSegmenter else {
            return
        }
        capture.isPreparingSegmenter = true
        Task.detached(priority: .utility) { [weak self] in
            let result = Result {
                try MediaPipeSelfieSegmentationModel(
                    modelURL: BackgroundRemovalModelResource.modelURL(),
                    sourceWidth: request.width,
                    sourceHeight: request.height
                )
            }
            await self?.finishPreparingBackgroundRemoval(result, for: request)
        }
    }

    func release(request: ProgramCameraInputRequest) async {
        guard let capture = capturesByRequest[request] else {
            return
        }
        capture.referenceCount = max(capture.referenceCount - 1, 0)
        if capture.referenceCount == 0 {
            await capture.captureService.stop()
            capturesByRequest.removeValue(forKey: request)
        }
    }

    func release() async {
        for request in Array(capturesByRequest.keys) {
            await release(request: request)
        }
    }

    func updateRetainedRequest(_ request: ProgramCameraInputRequest) async throws {
        try await retain(request: request)
    }

    func source(for request: ProgramCameraInputRequest) -> MetalVideoSource? {
        latestSource(for: request)
    }

    func latestSource(
        for request: ProgramCameraInputRequest,
        removingBackground: Bool = false
    ) -> MetalVideoSource? {
        latestFrame(
            for: request,
            removesBackground: removingBackground
        )?.source
    }

    func latestFrame(
        for request: ProgramCameraInputRequest,
        removingBackground: Bool = false
    ) -> ProgramCameraInputSourceFrame? {
        latestFrame(
            for: request,
            removesBackground: removingBackground
        )
    }

    func latestFrame(
        for request: ProgramCameraInputRequest,
        removesBackground: Bool
    ) -> ProgramCameraInputSourceFrame? {
        guard let capture = capturesByRequest[request],
              let latestFrame = capture.frameRing[capture.latestFrameIndex] else {
            return nil
        }
        let serial = capture.latestFrameSerial
        if removesBackground {
            guard capture.segmenter != nil else {
                return ProgramCameraInputSourceFrame(
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
                return ProgramCameraInputSourceFrame(
                    serial: serial,
                    source: .pixelBuffer(latestFrame.pixelBuffer),
                    sourcePresentationTime: latestFrame.presentationTime,
                    isPreparingRenderResources: false
                )
            }
            return ProgramCameraInputSourceFrame(
                serial: serial,
                source: .pixelBufferWithAlphaMask(latestFrame.pixelBuffer, alphaMask),
                sourcePresentationTime: latestFrame.presentationTime,
                isPreparingRenderResources: false
            )
        }
        return ProgramCameraInputSourceFrame(
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
        for capture in capturesByRequest.values {
            await capture.captureService.stop()
        }
        capturesByRequest = [:]
    }

    private func startCapture(
        request: ProgramCameraInputRequest,
        capture: ProgramCameraInputCapture
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

                let sample = ProgramCameraInputSample(sampleBuffer: sampleBuffer)
                Task { [weak self, sample] in
                    await self?.enqueue(sample, for: request)
                }
            }
        )
    }

    private func enqueue(_ sample: ProgramCameraInputSample, for request: ProgramCameraInputRequest) {
        guard let capture = capturesByRequest[request] else {
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

    private func drainPendingSample(for request: ProgramCameraInputRequest) {
        guard let capture = capturesByRequest[request] else {
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

    private func append(_ sample: ProgramCameraInputSample, for request: ProgramCameraInputRequest) {
        guard let capture = capturesByRequest[request],
              let copiedFrame = copyFrame(sample.sampleBuffer, capture: capture) else {
            return
        }
        setLatestFrame(copiedFrame, for: capture)
    }

    private func copyFrame(
        _ sampleBuffer: CMSampleBuffer,
        capture: ProgramCameraInputCapture
    ) -> ProgramCameraInputFrame? {
        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let destinationPixelBuffer = makeCopyDestinationPixelBuffer(for: sourcePixelBuffer, capture: capture),
              copyPixelBuffer(sourcePixelBuffer, to: destinationPixelBuffer) else {
            return nil
        }
        return ProgramCameraInputFrame(
            pixelBuffer: destinationPixelBuffer,
            presentationTime: sampleBuffer.presentationTimeStamp
        )
    }

    private func makeBackgroundRemovalAlphaMask(
        from pixelBuffer: CVPixelBuffer,
        capture: ProgramCameraInputCapture
    ) -> CVPixelBuffer? {
        guard let alphaMask = makeAlphaMaskPixelBuffer(for: pixelBuffer, capture: capture),
              renderAlphaMaskPixelBuffer(pixelBuffer, to: alphaMask, capture: capture) else {
            return nil
        }
        return alphaMask
    }

    private func makeCopyDestinationPixelBuffer(
        for sourcePixelBuffer: CVPixelBuffer,
        capture: ProgramCameraInputCapture
    ) -> CVPixelBuffer? {
        let request = InputDeviceResourceManager.PixelBufferRequest(pixelBuffer: sourcePixelBuffer)
        guard request == capture.copyPixelBufferRequest else {
            return nil
        }
        return try? inputDeviceResourceManager.pixelBuffer(for: capture.copyPixelBufferRequest)
    }

    private func makeAlphaMaskPixelBuffer(
        for sourcePixelBuffer: CVPixelBuffer,
        capture: ProgramCameraInputCapture
    ) -> CVPixelBuffer? {
        let request = InputDeviceResourceManager.PixelBufferRequest(
            width: CVPixelBufferGetWidth(sourcePixelBuffer),
            height: CVPixelBufferGetHeight(sourcePixelBuffer),
            pixelFormat: kCVPixelFormatType_OneComponent8
        )
        guard request == capture.alphaMaskPixelBufferRequest else {
            return nil
        }
        return try? inputDeviceResourceManager.pixelBuffer(for: capture.alphaMaskPixelBufferRequest)
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
        capture: ProgramCameraInputCapture
    ) -> Bool {
        guard let segmenter = capture.segmenter else {
            return false
        }
        return segmenter.renderAlphaMaskPixelBuffer(source, to: alphaMask)
    }

    private func setLatestFrame(
        _ frame: ProgramCameraInputFrame,
        for capture: ProgramCameraInputCapture
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
        for request: ProgramCameraInputRequest
    ) {
        guard let capture = capturesByRequest[request] else {
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

private final class ProgramCameraInputCapture {
    let captureService = CameraCaptureService()
    var segmenter: MediaPipeSelfieSegmentationModel?
    var isPreparingSegmenter = false
    var referenceCount = 0
    let copyPixelBufferRequest: InputDeviceResourceManager.PixelBufferRequest
    let alphaMaskPixelBufferRequest: InputDeviceResourceManager.PixelBufferRequest
    var pendingSample: ProgramCameraInputSample?
    var isDrainingSamples = false
    var frameRing: [ProgramCameraInputFrame?] = Array(repeating: nil, count: 3)
    var latestFrameIndex = 0
    var latestFrameSerial = 0
    var backgroundRemovalAlphaMask: CVPixelBuffer?
    var backgroundRemovalAlphaMaskSourceFrameSerial = -1
    var backgroundRemovalInferenceGateSourceFrameSerial = -1
    let backgroundRemovalInferenceGate = BackgroundRemovalInferenceGate()

    init(request: ProgramCameraInputRequest) {
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

    private var pixelBufferPools: [PixelBufferRequest: CVPixelBufferPool] = [:]

    func pixelBuffer(for request: PixelBufferRequest) throws -> CVPixelBuffer {
        let pool = try pixelBufferPool(for: request)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw VideoCompositorError.outputPixelBufferCreationFailed(status)
        }
        return pixelBuffer
    }

    private func pixelBufferPool(for request: PixelBufferRequest) throws -> CVPixelBufferPool {
        if let pixelBufferPool = pixelBufferPools[request] {
            return pixelBufferPool
        }

        let pixelBufferPool = try Self.makePixelBufferPool(for: request)
        pixelBufferPools[request] = pixelBufferPool
        return pixelBufferPool
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

private struct ProgramCameraInputSample: @unchecked Sendable {
    var sampleBuffer: CMSampleBuffer
}

struct ProgramCameraInputRequest: Hashable, Sendable {
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
}

struct ProgramCameraInputSourceFrame: Sendable {
    var serial: Int
    var source: MetalVideoSource
    var sourcePresentationTime: CMTime
    var isPreparingRenderResources: Bool = false
}

private struct ProgramCameraInputFrame: @unchecked Sendable {
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
