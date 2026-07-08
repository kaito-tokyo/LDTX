// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Combine
import CoreMedia
import CoreVideo
import Foundation
import LDTXProgram
import LDTXProgramRendering
import LDTXVideoComposition
import LDTXVideoRendering
import OSLog

public enum ProgramPreviewError: Error {
    case pixelBufferCreationFailed
}

public struct ProgramPreviewSnapshot: Sendable {
    public var definition: ProgramDefinition
    public var composite: CompositeProgramDefinition
    public var audioChannels: [ProgramAudioChannel]
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var outputWidth: Int
    public var outputHeight: Int
    public var frameRate: Int
    public var timeSeconds: Float
    public var programVideoPTSInputKey: String?
    public var programAudioDriverKey: String?
    public var cameraIDsByInputKey: [String: String]
    public var cameraInputColorOverrides: [String: CameraInputColorRangeOverride]
    public var backgroundRemovalInputKeys: Set<String>

    public init(
        definition: ProgramDefinition,
        composite: CompositeProgramDefinition,
        audioChannels: [ProgramAudioChannel],
        canvasWidth: Int,
        canvasHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        frameRate: Int,
        timeSeconds: Float,
        programVideoPTSInputKey: String?,
        programAudioDriverKey: String?,
        cameraIDsByInputKey: [String: String],
        cameraInputColorOverrides: [String: CameraInputColorRangeOverride],
        backgroundRemovalInputKeys: Set<String>
    ) {
        self.definition = definition
        self.composite = composite
        self.audioChannels = audioChannels
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.frameRate = frameRate
        self.timeSeconds = timeSeconds
        self.programVideoPTSInputKey = programVideoPTSInputKey
        self.programAudioDriverKey = programAudioDriverKey
        self.cameraIDsByInputKey = cameraIDsByInputKey
        self.cameraInputColorOverrides = cameraInputColorOverrides
        self.backgroundRemovalInputKeys = backgroundRemovalInputKeys
    }

    public var diagnosticDescription: String {
        "definition=\(definition.debugName), canvas=\(canvasWidth)x\(canvasHeight), output=\(outputWidth)x\(outputHeight), fps=\(frameRate), programVideoPTSInputKey=\(programVideoPTSInputKey ?? "nil"), programAudioDriverKey=\(programAudioDriverKey ?? "nil"), cameraIDs=\(cameraIDsByInputKey), cameraInputColorOverrides=\(cameraInputColorOverrides), backgroundRemovalInputKeys=\(backgroundRemovalInputKeys.sorted()), audioChannels=\(audioChannels.map { $0.component.definition.rawValue }.joined(separator: ",")), steps=\(composite.steps.map { $0.component.definition.rawValue }.joined(separator: ","))"
    }
}

private extension ProgramDefinition {
    var debugName: String {
        switch self {
        case .fillSolidColor:
            "fillSolidColor"
        case .fillLinearGradient:
            "fillLinearGradient"
        case .fillRadialGradient:
            "fillRadialGradient"
        case .fillConicGradient:
            "fillConicGradient"
        case .inputCameraDevice:
            "inputCameraDevice"
        case .testPattern:
            "testPattern"
        case .composite:
            "composite"
        }
    }
}

public struct ProgramPreviewFrame: @unchecked Sendable {
    var pixelBuffer: CVPixelBuffer
    var presentationTime: CMTime?
    var isPreparingRenderResources: Bool = false
}

public final class ProgramPreviewController: ObservableObject, @unchecked Sendable {
    private let lock = NSLock()
    private let previewRenderer: ProgramPreviewRenderWorker
    private var renderTask: Task<Void, Never>?
    private var snapshot: ProgramPreviewSnapshot?
    private var latestFrame: ProgramPreviewFrame?
    private var sessionID = 0

    public init(captureSessionCoordinator: WorkspaceCaptureSessionCoordinator) {
        previewRenderer = ProgramPreviewRenderWorker(
            captureSessionCoordinator: captureSessionCoordinator,
            captureRequestMode: .persistentInputDevicePreview
        )
    }

    public func configure(snapshot: ProgramPreviewSnapshot) {
        lock.lock()
        let shouldClearFrame = self.snapshot?.outputWidth != snapshot.outputWidth ||
            self.snapshot?.outputHeight != snapshot.outputHeight
        self.snapshot = snapshot
        if shouldClearFrame {
            latestFrame = nil
        }
        lock.unlock()
    }

    public func start(priority: TaskPriority = .userInitiated) {
        let currentSessionID: Int
        lock.lock()
        guard renderTask == nil else {
            lock.unlock()
            return
        }
        sessionID += 1
        currentSessionID = sessionID
        lock.unlock()

        renderTask = Task(priority: priority) { [weak self] in
            await self?.runRenderLoop(sessionID: currentSessionID)
        }
    }

    public func stop() {
        let currentSessionID: Int
        lock.lock()
        currentSessionID = sessionID
        renderTask?.cancel()
        renderTask = nil
        latestFrame = nil
        lock.unlock()

        let previewRenderer = previewRenderer
        Task {
            await previewRenderer.endSession(currentSessionID)
        }
    }

    public func latestPixelBuffer() -> CVPixelBuffer? {
        lock.lock()
        let pixelBuffer = latestFrame?.pixelBuffer
        lock.unlock()
        return pixelBuffer
    }

    public func isPreparingRenderResources() -> Bool {
        lock.lock()
        let isPreparing = latestFrame?.isPreparingRenderResources ?? false
        lock.unlock()
        return isPreparing
    }

    private func currentSnapshot() -> ProgramPreviewSnapshot? {
        lock.lock()
        let snapshot = snapshot
        lock.unlock()
        return snapshot
    }

    private func setLatestFrame(_ frame: ProgramPreviewFrame) {
        lock.lock()
        latestFrame = frame
        lock.unlock()
    }

    private func runRenderLoop(sessionID: Int) async {
        await previewRenderer.beginSession(sessionID)

        while !Task.isCancelled {
            guard var snapshot = currentSnapshot() else {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            snapshot.timeSeconds = Float(ProcessInfo.processInfo.systemUptime)
            do {
                let frame = try await previewRenderer.render(
                    snapshot: snapshot,
                    sessionID: sessionID
                )
                guard !Task.isCancelled else {
                    return
                }
                setLatestFrame(frame)
            } catch {
                if error is CancellationError {
                    return
                }
                logProgramPreviewRenderFailed(error, snapshot: snapshot)
            }

            let frameRate = max(snapshot.frameRate, 1)
            let interval = 1_000_000_000 / UInt64(frameRate)
            try? await Task.sleep(nanoseconds: interval)
        }
    }
}

actor ProgramPreviewRenderWorker {
    enum CaptureRequestMode {
        case activeOutput
        case persistentInputDevicePreview
    }

    private var activeSessionID: Int?
    private var compositor: VideoCompositor?
    private let captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
    private let captureRequestMode: CaptureRequestMode
    private var outputPixelBuffers: [CVPixelBuffer] = []
    private var nextOutputPixelBufferIndex = 0
    private var activeWidth: Int?
    private var activeHeight: Int?
    private var reusableRequestsByInputKey: [String: WorkspaceCaptureSessionRequest] = [:]
    private var reusableSourcesByInputKey: [String: MetalVideoSource] = [:]
    private var reusableActiveOutputRequests: Set<WorkspaceCaptureSessionRequest> = []
    private var reusableComponentCommands: [MetalVideoComponentCommand] = []

    init(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
        captureRequestMode: CaptureRequestMode = .activeOutput
    ) {
        self.captureSessionCoordinator = captureSessionCoordinator
        self.captureRequestMode = captureRequestMode
    }

    func beginSession(_ sessionID: Int) {
        activeSessionID = sessionID
    }

    func endSession(_ sessionID: Int) async {
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        if captureRequestMode == .activeOutput {
            await captureSessionCoordinator.releaseActiveOutputCaptures(sessionID: sessionID)
        }
    }

    func render(
        snapshot: ProgramPreviewSnapshot,
        sessionID: Int
    ) async throws -> ProgramPreviewFrame {
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
                snapshot: snapshot,
                sessionID: sessionID
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
            return ProgramPreviewFrame(
                pixelBuffer: outputPixelBuffer,
                presentationTime: presentationTime,
                isPreparingRenderResources: isPreparingRenderResources
            )
        } catch {
            if !(error is CancellationError) {
                logProgramPreviewWorkerFailed(error, snapshot: snapshot)
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
        ))
        self.compositor = compositor
        return compositor
    }

    private func refreshSources(
        snapshot: ProgramPreviewSnapshot,
        sessionID: Int
    ) async -> (
        presentationTime: CMTime?,
        isPreparingRenderResources: Bool
    ) {
        reusableRequestsByInputKey.removeAll(keepingCapacity: true)
        reusableRequestsByInputKey.reserveCapacity(snapshot.cameraIDsByInputKey.count)
        for (key, cameraID) in snapshot.cameraIDsByInputKey {
            reusableRequestsByInputKey[key] = WorkspaceCaptureSessionRequest(
                cameraID: cameraID,
                width: snapshot.outputWidth,
                height: snapshot.outputHeight,
                frameRate: snapshot.frameRate
            )
        }
        if captureRequestMode == .activeOutput {
            reusableActiveOutputRequests.removeAll(keepingCapacity: true)
            reusableActiveOutputRequests.reserveCapacity(reusableRequestsByInputKey.count)
            for request in reusableRequestsByInputKey.values {
                reusableActiveOutputRequests.insert(request)
            }
            _ = await captureSessionCoordinator.synchronizeActiveOutputCaptures(
                sessionID: sessionID,
                requests: reusableActiveOutputRequests
            )
        }

        for (key, request) in reusableRequestsByInputKey {
            if snapshot.backgroundRemovalInputKeys.contains(key) {
                await captureSessionCoordinator.beginPreparingBackgroundRemoval(for: request)
            }
        }

        reusableSourcesByInputKey.removeAll(keepingCapacity: true)
        reusableSourcesByInputKey.reserveCapacity(reusableRequestsByInputKey.count)
        var presentationTime: CMTime?
        var isPreparingRenderResources = false
        for (key, request) in reusableRequestsByInputKey {
            if let frame = await captureSessionCoordinator.latestFrame(
                for: request,
                removesBackground: snapshot.backgroundRemovalInputKeys.contains(key)
            ) {
                reusableSourcesByInputKey[key] = frame.source
                if key == snapshot.programVideoPTSInputKey {
                    presentationTime = frame.sourcePresentationTime
                }
                isPreparingRenderResources = isPreparingRenderResources || frame.isPreparingRenderResources
            }
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
            logProgramPreviewPixelBufferCreateFailed(
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

private func logProgramPreviewRenderFailed(_ error: Error, snapshot: ProgramPreviewSnapshot) {
    let nsError = error as NSError
    programPreviewLogger.error(
        "Program preview render failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) canvasWidth=\(snapshot.canvasWidth, privacy: .public) canvasHeight=\(snapshot.canvasHeight, privacy: .public) outputWidth=\(snapshot.outputWidth, privacy: .public) outputHeight=\(snapshot.outputHeight, privacy: .public) frameRate=\(snapshot.frameRate, privacy: .public) timeSeconds=\(snapshot.timeSeconds, privacy: .public) cameraInputCount=\(snapshot.cameraIDsByInputKey.count, privacy: .public) backgroundRemovalInputCount=\(snapshot.backgroundRemovalInputKeys.count, privacy: .public) stepCount=\(snapshot.composite.steps.count, privacy: .public)"
    )
}

private func logProgramPreviewWorkerFailed(_ error: Error, snapshot: ProgramPreviewSnapshot) {
    let nsError = error as NSError
    programPreviewLogger.error(
        "Program preview worker failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) canvasWidth=\(snapshot.canvasWidth, privacy: .public) canvasHeight=\(snapshot.canvasHeight, privacy: .public) outputWidth=\(snapshot.outputWidth, privacy: .public) outputHeight=\(snapshot.outputHeight, privacy: .public) frameRate=\(snapshot.frameRate, privacy: .public) timeSeconds=\(snapshot.timeSeconds, privacy: .public) cameraInputCount=\(snapshot.cameraIDsByInputKey.count, privacy: .public) backgroundRemovalInputCount=\(snapshot.backgroundRemovalInputKeys.count, privacy: .public) stepCount=\(snapshot.composite.steps.count, privacy: .public)"
    )
}

private func logProgramPreviewPixelBufferCreateFailed(
    status: CVReturn,
    width: Int,
    height: Int,
    pixelFormat: OSType
) {
    programPreviewLogger.error(
        "Program preview pixel buffer creation failed status=\(status, privacy: .public) width=\(width, privacy: .public) height=\(height, privacy: .public) pixelFormat=\(pixelFormat, privacy: .public)"
    )
}

private let programPreviewLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "ProgramPreview"
)
