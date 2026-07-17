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

public struct ProgramFrame {
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
    public typealias FrameHandler = (ProgramFrame) -> Void
    private let lock = NSLock()
    private let renderer: ActiveProgramRenderer
    private let scheduler: any ProgramRuntimeScheduling
    private let renderQueue = DispatchQueue(label: "tokyo.kaito.ldtx.ActiveProgramRuntime.render", qos: .userInitiated)
    private var renderTimer: DispatchSourceTimer?
    private var framePacer = ProgramFramePacer()
    private var previewSnapshot: ProgramPreviewSnapshot?
    private var outputSnapshot: ProgramPreviewSnapshot?
    private var latestPublishedFrame: ProgramFrame?
    private var frameHandlersByID: [UUID: FrameHandler] = [:]
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
            renderQueue.async { [renderer] in
                renderer.endSession(sessionToEnd)
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
            renderQueue.async { [renderer] in
                renderer.endSession(sessionToEnd)
            }
        }
    }

    public func latestFrame() -> ProgramFrame? {
        lock.withLock {
            latestPublishedFrame
        }
    }

    @discardableResult
    public func addFrameHandler(_ handler: @escaping FrameHandler) -> UUID {
        let handlerID = UUID()
        let latestFrame = lock.withLock { () -> ProgramFrame? in
            frameHandlersByID[handlerID] = handler
            ensureRenderLoopLocked()
            return latestPublishedFrame
        }
        if let latestFrame {
            handler(latestFrame)
        }
        return handlerID
    }

    public func removeFrameHandler(id: UUID) {
        let sessionToEnd = lock.withLock { () -> Int? in
            frameHandlersByID.removeValue(forKey: id)
            return stopRenderLoopIfIdleLocked()
        }
        if let sessionToEnd {
            renderQueue.async { [renderer] in
                renderer.endSession(sessionToEnd)
            }
        }
    }

    private func currentSnapshotLocked() -> ProgramPreviewSnapshot? {
        outputSnapshot ?? previewSnapshot
    }

    private func shouldRenderLocked() -> Bool {
        previewConsumerCount > 0 || !frameHandlersByID.isEmpty
    }

    private func ensureRenderLoopLocked() {
        guard renderTimer == nil, shouldRenderLocked() else {
            return
        }
        sessionID += 1
        let currentSessionID = sessionID
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.setEventHandler { [weak self] in
            self?.renderTick(sessionID: currentSessionID)
        }
        renderTimer = timer
        renderQueue.async { [weak self, renderer] in
            self?.framePacer = ProgramFramePacer()
            renderer.beginSession(currentSessionID)
            timer.schedule(deadline: .now())
            timer.resume()
        }
    }

    private func stopRenderLoopIfIdleLocked() -> Int? {
        guard !shouldRenderLocked() else {
            return nil
        }
        let sessionToEnd = sessionID
        renderTimer?.setEventHandler {}
        renderTimer?.cancel()
        renderTimer = nil
        return sessionToEnd == 0 ? nil : sessionToEnd
    }

    private func nextFrameIDValue() -> UInt64 {
        lock.withLock {
            nextProducedFrameID &+= 1
            return nextProducedFrameID
        }
    }

    private func renderTick(sessionID: Int) {
        dispatchPrecondition(condition: .onQueue(renderQueue))
        guard let timer = lock.withLock({ () -> DispatchSourceTimer? in
            guard self.sessionID == sessionID else { return nil }
            return renderTimer
        }) else {
            renderer.endSession(sessionID)
            return
        }
        guard var snapshot = lock.withLock({ currentSnapshotLocked() }) else {
            timer.schedule(deadline: .now() + .milliseconds(100))
            return
        }
        let delayNanoseconds = framePacer.delayBeforeNextFrame(
            nowNanoseconds: scheduler.nowNanoseconds,
            frameRate: snapshot.frameRate
        )
        if delayNanoseconds > 0 {
            timer.schedule(deadline: .now() + .nanoseconds(Int(clamping: delayNanoseconds)))
            return
        }
        snapshot.timeSeconds = Float(scheduler.uptimeSeconds)
        do {
            let frame = try renderer.render(
                snapshot: snapshot,
                sessionID: sessionID,
                frameID: nextFrameIDValue()
            )
            publish(frame)
        } catch {
            if error is CancellationError {
                return
            }
            logActiveProgramRenderFailed(error, snapshot: snapshot)
        }
        timer.schedule(deadline: .now())
    }

    private func publish(_ frame: ProgramFrame) {
        let handlers = lock.withLock { () -> [FrameHandler] in
            latestPublishedFrame = frame
            return Array(frameHandlersByID.values)
        }
        if frame.frameID == 1 || frame.frameID.isMultiple(of: 120) {
            activeProgramRuntimeLogger.notice(
                "Published program frame frameID=\(frame.frameID, privacy: .public) hasPTS=\(frame.presentationTime != nil, privacy: .public) handlerCount=\(handlers.count, privacy: .public)"
            )
        }
        for handler in handlers {
            handler(frame)
        }
    }
}

/// Mutable rendering state confined to the owning runtime's render queue.
final class ActiveProgramRenderer: @unchecked Sendable {
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
    private var videoPTSSelector = ProgramVideoPTSSelector()
    private var missingMasterPTSFrameCount: UInt64 = 0

    init(captureSessionCoordinator: WorkspaceCaptureSessionCoordinator) {
        self.captureSessionCoordinator = captureSessionCoordinator
    }

    func beginSession(_ sessionID: Int) {
        activeSessionID = sessionID
        videoPTSSelector.reset()
        missingMasterPTSFrameCount = 0
    }

    func endSession(_ sessionID: Int) {
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
    }

    func render(
        snapshot: ProgramPreviewSnapshot,
        sessionID: Int,
        frameID: UInt64
    ) throws -> ProgramFrame {
        guard activeSessionID == sessionID else {
            throw CancellationError()
        }

        let outputWidth = max(snapshot.outputWidth, 1)
        let outputHeight = max(snapshot.outputHeight, 1)
        let canvasWidth = max(snapshot.canvasWidth, 1)
        let canvasHeight = max(snapshot.canvasHeight, 1)
        do {
            try prepareSize(width: outputWidth, height: outputHeight)
            let compositor = try makeCompositor(width: outputWidth, height: outputHeight)
            let (presentationTime, isPreparingRenderResources) = refreshSources(
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

    private func prepareSize(width: Int, height: Int) throws {
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
    ) -> (
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
                captureSessionCoordinator.beginPreparingBackgroundRemoval(forCameraID: cameraID)
            }
        }

        reusableSourcesByInputKey.removeAll(keepingCapacity: true)
        reusableSourcesByInputKey.reserveCapacity(reusableCameraIDsByInputKey.count)
        var presentationTimesByInputKey: [String: CMTime] = [:]
        var isPreparingRenderResources = false
        for (key, cameraID) in reusableCameraIDsByInputKey {
            if let frame = captureSessionCoordinator.latestFrame(
                forCameraID: cameraID,
                removesBackground: snapshot.backgroundRemovalInputKeys.contains(key)
            ) {
                reusableSourcesByInputKey[key] = frame.source
                presentationTimesByInputKey[key] = frame.sourcePresentationTime
                isPreparingRenderResources = isPreparingRenderResources || frame.isPreparingRenderResources
            }
        }
        let ptsDecision = videoPTSSelector.select(
            masterKey: snapshot.programVideoPTSInputKey,
            presentationTimesByInputKey: presentationTimesByInputKey
        )
        let presentationTime: CMTime? = switch ptsDecision {
        case let .advanced(value):
            value
        case .waitingForMasterPTS, .stalled, .rejectedNonMonotonic, .rejectedMasterSourceChange:
            nil
        }
        switch ptsDecision {
        case .waitingForMasterPTS, .rejectedNonMonotonic, .rejectedMasterSourceChange:
            missingMasterPTSFrameCount &+= 1
            if missingMasterPTSFrameCount == 1 || missingMasterPTSFrameCount.isMultiple(of: 120) {
                let masterKey = snapshot.programVideoPTSInputKey ?? "nil"
                let mappedKeys = snapshot.cameraIDsByInputKey.keys.sorted().joined(separator: ",")
                let availableKeys = presentationTimesByInputKey.keys.sorted().joined(separator: ",")
                let cameraIDs = snapshot.cameraIDsByInputKey.values.sorted().joined(separator: ",")
                activeProgramRuntimeLogger.notice(
                    "Program frame has no master PTS masterKey=\(masterKey, privacy: .public) mappedKeys=\(mappedKeys, privacy: .public) availableKeys=\(availableKeys, privacy: .public) cameraIDs=\(cameraIDs, privacy: .public)"
                )
            }
        case .advanced, .stalled:
            break
        }
        return (presentationTime, isPreparingRenderResources)
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
