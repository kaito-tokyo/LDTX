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

public final class ProgramPreviewController: ObservableObject, @unchecked Sendable {
    private enum Backend {
        case runtime(ActiveProgramRuntime)
        case standalone(ActiveProgramRenderer)
    }

    private let lock = NSLock()
    private let backend: Backend
    private var renderTask: Task<Void, Never>?
    private var snapshot: ProgramPreviewSnapshot?
    private var latestRenderedFrame: ProgramFrame?
    private var sessionID = 0
    private var nextRenderedFrameID: UInt64 = 0
    private var isPreviewRunning = false

    public init(captureSessionCoordinator: WorkspaceCaptureSessionCoordinator) {
        backend = .standalone(
            ActiveProgramRenderer(captureSessionCoordinator: captureSessionCoordinator)
        )
    }

    public init(activeProgramRuntime: ActiveProgramRuntime) {
        backend = .runtime(activeProgramRuntime)
    }

    public func configure(snapshot: ProgramPreviewSnapshot) {
        switch backend {
        case let .runtime(activeProgramRuntime):
            activeProgramRuntime.configurePreview(snapshot: snapshot)
        case .standalone:
            lock.lock()
            let shouldClearFrame = self.snapshot?.outputWidth != snapshot.outputWidth ||
                self.snapshot?.outputHeight != snapshot.outputHeight
            self.snapshot = snapshot
            if shouldClearFrame {
                latestRenderedFrame = nil
            }
            lock.unlock()
        }
    }

    public func start(priority: TaskPriority = .userInitiated) {
        switch backend {
        case let .runtime(activeProgramRuntime):
            let shouldStart = lock.withLock { () -> Bool in
                guard !isPreviewRunning else {
                    return false
                }
                isPreviewRunning = true
                return true
            }
            if shouldStart {
                activeProgramRuntime.startPreview()
            }
        case .standalone:
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
    }

    public func stop() {
        switch backend {
        case let .runtime(activeProgramRuntime):
            let shouldStop = lock.withLock { () -> Bool in
                guard isPreviewRunning else {
                    return false
                }
                isPreviewRunning = false
                return true
            }
            if shouldStop {
                activeProgramRuntime.stopPreview()
            }
        case let .standalone(previewRenderer):
            let currentSessionID: Int
            lock.lock()
            currentSessionID = sessionID
            renderTask?.cancel()
            renderTask = nil
            latestRenderedFrame = nil
            lock.unlock()

            Task {
                await previewRenderer.endSession(currentSessionID)
            }
        }
    }

    public func latestFrame() -> ProgramFrame? {
        switch backend {
        case let .runtime(activeProgramRuntime):
            activeProgramRuntime.latestFrame()
        case .standalone:
            lock.withLock {
                latestRenderedFrame
            }
        }
    }

    public func latestPixelBuffer() -> CVPixelBuffer? {
        latestFrame()?.pixelBuffer
    }

    public func isPreparingRenderResources() -> Bool {
        latestFrame()?.isPreparingRenderResources ?? false
    }

    private func currentSnapshot() -> ProgramPreviewSnapshot? {
        lock.withLock {
            snapshot
        }
    }

    private func nextStandaloneFrameID() -> UInt64 {
        lock.withLock {
            nextRenderedFrameID &+= 1
            return nextRenderedFrameID
        }
    }

    private func setLatestFrame(_ frame: ProgramFrame) {
        lock.withLock {
            latestRenderedFrame = frame
        }
    }

    private func runRenderLoop(sessionID: Int) async {
        guard case let .standalone(previewRenderer) = backend else {
            return
        }
        await previewRenderer.beginSession(sessionID)

        while !Task.isCancelled {
            guard var snapshot = currentSnapshot() else {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            snapshot.timeSeconds = Float(ProcessInfo.processInfo.systemUptime)
            do {
                var frame = try await previewRenderer.render(
                    snapshot: snapshot,
                    sessionID: sessionID,
                    frameID: nextStandaloneFrameID()
                )
                if frame.presentationTime == nil,
                   snapshot.programVideoPTSInputKey == nil {
                    frame.presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
                }
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

private func logProgramPreviewRenderFailed(_ error: Error, snapshot: ProgramPreviewSnapshot) {
    let nsError = error as NSError
    programPreviewLogger.error(
        "Program preview render failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) canvasWidth=\(snapshot.canvasWidth, privacy: .public) canvasHeight=\(snapshot.canvasHeight, privacy: .public) outputWidth=\(snapshot.outputWidth, privacy: .public) outputHeight=\(snapshot.outputHeight, privacy: .public) frameRate=\(snapshot.frameRate, privacy: .public) timeSeconds=\(snapshot.timeSeconds, privacy: .public) cameraInputCount=\(snapshot.cameraIDsByInputKey.count, privacy: .public) backgroundRemovalInputCount=\(snapshot.backgroundRemovalInputKeys.count, privacy: .public) stepCount=\(snapshot.composite.steps.count, privacy: .public)"
    )
}

private let programPreviewLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "ProgramPreview"
)
