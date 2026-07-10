// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import Foundation
import LDTXProgram
import LDTXProgramRendering
import LDTXVideoComposition
import LDTXVideoRendering
import OSLog
#if canImport(Metal)
import Metal
#endif

public struct ProgramFrame: @unchecked Sendable {
    public let frameID: UInt64
    public let pixelBuffer: CVPixelBuffer
    public var presentationTime: CMTime?
    public let isPreparingRenderResources: Bool

    public init(
        frameID: UInt64,
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime?,
        isPreparingRenderResources: Bool = false
    ) {
        self.frameID = frameID
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.isPreparingRenderResources = isPreparingRenderResources
    }
}

#if canImport(Metal)
public extension ProgramFrame {
    func makeCVMetalTexture(
        using textureCache: CVMetalTextureCache,
        pixelFormat: MTLPixelFormat,
        planeIndex: Int
    ) -> CVMetalTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        var cvMetalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvMetalTexture
        )
        guard status == kCVReturnSuccess,
              let cvMetalTexture else {
            return nil
        }
        return cvMetalTexture
    }

    func makeTexture(
        using textureCache: CVMetalTextureCache,
        pixelFormat: MTLPixelFormat,
        planeIndex: Int
    ) -> MTLTexture? {
        guard let cvMetalTexture = makeCVMetalTexture(
            using: textureCache,
            pixelFormat: pixelFormat,
            planeIndex: planeIndex
        ) else {
            return nil
        }
        return CVMetalTextureGetTexture(cvMetalTexture)
    }
}
#endif

public final class ActiveProgramRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private let renderer: ActiveProgramRenderer
    private let scheduler: any ProgramRuntimeScheduling
    private var renderTask: Task<Void, Never>?
    private var previewSnapshot: ProgramPreviewSnapshot?
    private var outputSnapshot: ProgramPreviewSnapshot?
    private var latestPublishedFrame: ProgramFrame?
    private var frameContinuationsByID: [UUID: AsyncStream<ProgramFrame>.Continuation] = [:]
    private var previewConsumerCount = 0
    private var sessionID = 0
    private var nextProducedFrameID: UInt64 = 0

    public init(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
        scheduler: any ProgramRuntimeScheduling = SystemProgramRuntimeScheduler()
    ) {
        renderer = ActiveProgramRenderer(captureSessionCoordinator: captureSessionCoordinator)
        self.scheduler = scheduler
    }

    public func configurePreview(snapshot: ProgramPreviewSnapshot) {
        lock.withLock {
            let previousCurrentSnapshot = currentSnapshotLocked()
            previewSnapshot = snapshot
            let currentSnapshot = currentSnapshotLocked()
            let shouldClearFrame = previousCurrentSnapshot?.outputWidth != currentSnapshot?.outputWidth ||
                previousCurrentSnapshot?.outputHeight != currentSnapshot?.outputHeight
            if shouldClearFrame {
                latestPublishedFrame = nil
            }
            ensureRenderLoopLocked()
        }
    }

    public func startPreview() {
        lock.withLock {
            previewConsumerCount += 1
            ensureRenderLoopLocked()
        }
    }

    public func stopPreview() {
        let sessionToEnd = lock.withLock { () -> Int? in
            previewConsumerCount = max(previewConsumerCount - 1, 0)
            return stopRenderLoopIfIdleLocked()
        }
        if let sessionToEnd {
            Task {
                await renderer.endSession(sessionToEnd)
            }
        }
    }

    public func beginOutput(snapshot: ProgramPreviewSnapshot) {
        lock.withLock {
            let previousCurrentSnapshot = currentSnapshotLocked()
            outputSnapshot = snapshot
            let currentSnapshot = currentSnapshotLocked()
            let shouldClearFrame = previousCurrentSnapshot?.outputWidth != currentSnapshot?.outputWidth ||
                previousCurrentSnapshot?.outputHeight != currentSnapshot?.outputHeight
            if shouldClearFrame {
                latestPublishedFrame = nil
            }
            ensureRenderLoopLocked()
        }
    }

    public func endOutput() {
        let sessionToEnd = lock.withLock { () -> Int? in
            let previousCurrentSnapshot = currentSnapshotLocked()
            outputSnapshot = nil
            let currentSnapshot = currentSnapshotLocked()
            let shouldClearFrame = previousCurrentSnapshot?.outputWidth != currentSnapshot?.outputWidth ||
                previousCurrentSnapshot?.outputHeight != currentSnapshot?.outputHeight
            if shouldClearFrame {
                latestPublishedFrame = nil
            }
            return stopRenderLoopIfIdleLocked()
        }
        if let sessionToEnd {
            Task {
                await renderer.endSession(sessionToEnd)
            }
        }
    }

    public func latestFrame() -> ProgramFrame? {
        lock.withLock {
            latestPublishedFrame
        }
    }

    public func frameStream() -> (id: UUID, stream: AsyncStream<ProgramFrame>) {
        let continuationID = UUID()
        let stream = AsyncStream<ProgramFrame>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let latestFrame = lock.withLock { () -> ProgramFrame? in
                frameContinuationsByID[continuationID] = continuation
                ensureRenderLoopLocked()
                return latestPublishedFrame
            }
            if let latestFrame {
                continuation.yield(latestFrame)
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeFrameStream(id: continuationID)
            }
        }
        return (continuationID, stream)
    }

    public func removeFrameStream(id: UUID) {
        let sessionToEnd = lock.withLock { () -> Int? in
            frameContinuationsByID.removeValue(forKey: id)
            return stopRenderLoopIfIdleLocked()
        }
        if let sessionToEnd {
            Task {
                await renderer.endSession(sessionToEnd)
            }
        }
    }

    private func currentSnapshotLocked() -> ProgramPreviewSnapshot? {
        outputSnapshot ?? previewSnapshot
    }

    private func shouldRenderLocked() -> Bool {
        previewConsumerCount > 0 || !frameContinuationsByID.isEmpty
    }

    private func ensureRenderLoopLocked() {
        guard renderTask == nil, shouldRenderLocked() else {
            return
        }
        sessionID += 1
        let currentSessionID = sessionID
        renderTask = Task(priority: .userInitiated) { [weak self] in
            await self?.runRenderLoop(sessionID: currentSessionID)
        }
    }

    private func stopRenderLoopIfIdleLocked() -> Int? {
        guard !shouldRenderLocked() else {
            return nil
        }
        let sessionToEnd = sessionID
        renderTask?.cancel()
        renderTask = nil
        return sessionToEnd == 0 ? nil : sessionToEnd
    }

    private func nextFrameIDValue() -> UInt64 {
        lock.withLock {
            nextProducedFrameID &+= 1
            return nextProducedFrameID
        }
    }

    private func runRenderLoop(sessionID: Int) async {
        await renderer.beginSession(sessionID)
        defer {
            Task {
                await renderer.endSession(sessionID)
            }
        }

        var framePacer = ProgramFramePacer()

        while !Task.isCancelled {
            guard var snapshot = lock.withLock({ currentSnapshotLocked() }) else {
                await scheduler.sleep(nanoseconds: 100_000_000)
                continue
            }

            let delayNanoseconds = framePacer.delayBeforeNextFrame(
                nowNanoseconds: scheduler.nowNanoseconds,
                frameRate: snapshot.frameRate
            )
            if delayNanoseconds > 0 {
                await scheduler.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled else {
                    return
                }
            }

            snapshot.timeSeconds = Float(scheduler.uptimeSeconds)
            do {
                let frame = try await renderer.render(
                    snapshot: snapshot,
                    sessionID: sessionID,
                    frameID: nextFrameIDValue()
                )
                guard !Task.isCancelled else {
                    return
                }
                publish(frame)
            } catch {
                if error is CancellationError {
                    return
                }
                logActiveProgramRenderFailed(error, snapshot: snapshot)
            }

        }
    }

    private func publish(_ frame: ProgramFrame) {
        let continuations = lock.withLock { () -> [AsyncStream<ProgramFrame>.Continuation] in
            latestPublishedFrame = frame
            return Array(frameContinuationsByID.values)
        }
        for continuation in continuations {
            continuation.yield(frame)
        }
    }
}

actor ActiveProgramRenderer {
    private var activeSessionID: Int?
    private var compositor: VideoCompositor?
    private let captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
    private var outputPixelBuffers: [CVPixelBuffer] = []
    private var nextOutputPixelBufferIndex = 0
    private var activeWidth: Int?
    private var activeHeight: Int?
    private var reusableCameraIDsByInputKey: [String: String] = [:]
    private var reusableSourcesByInputKey: [String: MetalVideoSource] = [:]
    private var reusableComponentCommands: [MetalVideoComponentCommand] = []

    init(captureSessionCoordinator: WorkspaceCaptureSessionCoordinator) {
        self.captureSessionCoordinator = captureSessionCoordinator
    }

    func beginSession(_ sessionID: Int) {
        activeSessionID = sessionID
    }

    func endSession(_ sessionID: Int) async {
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
    }

    func render(
        snapshot: ProgramPreviewSnapshot,
        sessionID: Int,
        frameID: UInt64
    ) async throws -> ProgramFrame {
        guard activeSessionID == sessionID else {
            throw CancellationError()
        }

        let outputWidth = max(snapshot.outputWidth, 1)
        let outputHeight = max(snapshot.outputHeight, 1)
        let canvasWidth = max(snapshot.canvasWidth, 1)
        let canvasHeight = max(snapshot.canvasHeight, 1)
        do {
            try await prepareSize(width: outputWidth, height: outputHeight)
            let compositor = try makeCompositor(width: outputWidth, height: outputHeight)
            let (presentationTime, isPreparingRenderResources) = await refreshSources(
                snapshot: snapshot
            )
            let outputPixelBuffer = try makeOutputPixelBuffer(width: outputWidth, height: outputHeight)
            reusableComponentCommands.removeAll(keepingCapacity: true)
            snapshot.definition.appendComponentCommands(
                to: &reusableComponentCommands,
                worldWidth: canvasWidth,
                worldHeight: canvasHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                composite: snapshot.composite,
                sourceForInputKey: { key in
                    self.reusableSourcesByInputKey[key]
                },
                colorRangeForInputKey: { key in
                    snapshot.cameraInputColorOverrides[key] ?? .unspecified
                },
                timeSeconds: snapshot.timeSeconds
            )
            try compositor.renderCommands(reusableComponentCommands, into: outputPixelBuffer)
            return ProgramFrame(
                frameID: frameID,
                pixelBuffer: outputPixelBuffer,
                presentationTime: presentationTime,
                isPreparingRenderResources: isPreparingRenderResources
            )
        } catch {
            if !(error is CancellationError) {
                logActiveProgramRendererFailed(error, snapshot: snapshot)
            }
            throw error
        }
    }

    private func prepareSize(width: Int, height: Int) async throws {
        if activeWidth == width && activeHeight == height {
            return
        }

        compositor = nil
        outputPixelBuffers = try (0..<3).map { _ in
            try Self.makeNV12PixelBuffer(width: width, height: height)
        }
        nextOutputPixelBufferIndex = 0
        activeWidth = width
        activeHeight = height
    }

    private func makeCompositor(width: Int, height: Int) throws -> VideoCompositor {
        if let compositor {
            return compositor
        }
        let compositor = try VideoCompositor(configuration: VideoCompositorConfiguration(
            width: width,
            height: height,
            pixelBufferPoolMinimumBufferCount: 3
        ), device: captureSessionCoordinator.metalDevice)
        self.compositor = compositor
        return compositor
    }

    private func refreshSources(
        snapshot: ProgramPreviewSnapshot
    ) async -> (
        presentationTime: CMTime?,
        isPreparingRenderResources: Bool
    ) {
        reusableCameraIDsByInputKey.removeAll(keepingCapacity: true)
        reusableCameraIDsByInputKey.reserveCapacity(snapshot.cameraIDsByInputKey.count)
        for (key, cameraID) in snapshot.cameraIDsByInputKey {
            reusableCameraIDsByInputKey[key] = cameraID
        }

        for (key, cameraID) in reusableCameraIDsByInputKey {
            if snapshot.backgroundRemovalInputKeys.contains(key) {
                await captureSessionCoordinator.beginPreparingBackgroundRemoval(forCameraID: cameraID)
            }
        }

        reusableSourcesByInputKey.removeAll(keepingCapacity: true)
        reusableSourcesByInputKey.reserveCapacity(reusableCameraIDsByInputKey.count)
        var presentationTime: CMTime?
        var fallbackPresentationTime: CMTime?
        var isPreparingRenderResources = false
        for (key, cameraID) in reusableCameraIDsByInputKey {
            if let frame = await captureSessionCoordinator.latestFrame(
                forCameraID: cameraID,
                removesBackground: snapshot.backgroundRemovalInputKeys.contains(key)
            ) {
                reusableSourcesByInputKey[key] = frame.source
                if key == snapshot.programVideoPTSInputKey {
                    presentationTime = frame.sourcePresentationTime
                } else if fallbackPresentationTime == nil {
                    fallbackPresentationTime = frame.sourcePresentationTime
                }
                isPreparingRenderResources = isPreparingRenderResources || frame.isPreparingRenderResources
            }
        }
        return (presentationTime ?? fallbackPresentationTime, isPreparingRenderResources)
    }

    private func makeOutputPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        guard !outputPixelBuffers.isEmpty else {
            throw ProgramPreviewError.pixelBufferCreationFailed
        }
        let pixelBuffer = outputPixelBuffers[nextOutputPixelBufferIndex]
        nextOutputPixelBufferIndex = (nextOutputPixelBufferIndex + 1) % outputPixelBuffers.count
        return pixelBuffer
    }

    private static func makeNV12PixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            logActiveProgramPixelBufferCreateFailed(
                status: status,
                width: width,
                height: height,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            )
            throw ProgramPreviewError.pixelBufferCreationFailed
        }
        return pixelBuffer
    }
}

private func logActiveProgramRenderFailed(_ error: Error, snapshot: ProgramPreviewSnapshot) {
    let nsError = error as NSError
    activeProgramRuntimeLogger.error(
        "Active program render failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) canvasWidth=\(snapshot.canvasWidth, privacy: .public) canvasHeight=\(snapshot.canvasHeight, privacy: .public) outputWidth=\(snapshot.outputWidth, privacy: .public) outputHeight=\(snapshot.outputHeight, privacy: .public) frameRate=\(snapshot.frameRate, privacy: .public) timeSeconds=\(snapshot.timeSeconds, privacy: .public) cameraInputCount=\(snapshot.cameraIDsByInputKey.count, privacy: .public) backgroundRemovalInputCount=\(snapshot.backgroundRemovalInputKeys.count, privacy: .public) stepCount=\(snapshot.composite.steps.count, privacy: .public)"
    )
}

private func logActiveProgramRendererFailed(_ error: Error, snapshot: ProgramPreviewSnapshot) {
    let nsError = error as NSError
    activeProgramRuntimeLogger.error(
        "Active program renderer failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) canvasWidth=\(snapshot.canvasWidth, privacy: .public) canvasHeight=\(snapshot.canvasHeight, privacy: .public) outputWidth=\(snapshot.outputWidth, privacy: .public) outputHeight=\(snapshot.outputHeight, privacy: .public) frameRate=\(snapshot.frameRate, privacy: .public) timeSeconds=\(snapshot.timeSeconds, privacy: .public) cameraInputCount=\(snapshot.cameraIDsByInputKey.count, privacy: .public) backgroundRemovalInputCount=\(snapshot.backgroundRemovalInputKeys.count, privacy: .public) stepCount=\(snapshot.composite.steps.count, privacy: .public)"
    )
}

private func logActiveProgramPixelBufferCreateFailed(
    status: CVReturn,
    width: Int,
    height: Int,
    pixelFormat: OSType
) {
    activeProgramRuntimeLogger.error(
        "Active program pixel buffer creation failed status=\(status, privacy: .public) width=\(width, privacy: .public) height=\(height, privacy: .public) pixelFormat=\(pixelFormat, privacy: .public)"
    )
}

private let activeProgramRuntimeLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "ActiveProgramRuntime"
)
