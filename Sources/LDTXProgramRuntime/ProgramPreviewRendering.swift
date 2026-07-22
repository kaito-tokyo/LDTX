// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Combine
import CoreMedia
import CoreVideo
import Foundation
import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRendering
import LDTXVideoComposition
import OSLog

public enum ProgramPreviewError: Error {
    case pixelBufferCreationFailed
}

public struct ProgramPreviewSnapshot: Sendable {
    public var composite: CompositeProgramDefinition
    public var audioChannels: [ProgramAudioChannel]
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var outputWidth: Int
    public var outputHeight: Int
    public var frameRate: Int
    public var timeSeconds: Float
    public var programVideoPTSInputKey: String?
    public var cameraIDsByInputKey: [String: String]
    public var inputDeviceNamesByInputKey: [String: String]
    public var cameraInputColorOverrides: [String: CameraInputColorRangeOverride]
    public var backgroundRemovalInputKeys: Set<String>

    public init(
        composite: CompositeProgramDefinition,
        audioChannels: [ProgramAudioChannel],
        canvasWidth: Int,
        canvasHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        frameRate: Int,
        timeSeconds: Float,
        programVideoPTSInputKey: String?,
        cameraIDsByInputKey: [String: String],
        inputDeviceNamesByInputKey: [String: String] = [:],
        cameraInputColorOverrides: [String: CameraInputColorRangeOverride],
        backgroundRemovalInputKeys: Set<String>
    ) {
        self.composite = composite
        self.audioChannels = audioChannels
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.frameRate = frameRate
        self.timeSeconds = timeSeconds
        self.programVideoPTSInputKey = programVideoPTSInputKey
        self.cameraIDsByInputKey = cameraIDsByInputKey
        self.inputDeviceNamesByInputKey = inputDeviceNamesByInputKey
        self.cameraInputColorOverrides = cameraInputColorOverrides
        self.backgroundRemovalInputKeys = backgroundRemovalInputKeys
    }

    public var diagnosticDescription: String {
        "canvas=\(canvasWidth)x\(canvasHeight), output=\(outputWidth)x\(outputHeight), fps=\(frameRate), programVideoPTSInputKey=\(programVideoPTSInputKey ?? "nil"), cameraIDs=\(cameraIDsByInputKey), inputDeviceNames=\(inputDeviceNamesByInputKey), cameraInputColorOverrides=\(cameraInputColorOverrides), backgroundRemovalInputKeys=\(backgroundRemovalInputKeys.sorted()), audioChannels=\(audioChannels.map { $0.component.definition.rawValue }.joined(separator: ",")), steps=\(composite.steps.map { $0.component.definition.rawValue }.joined(separator: ","))"
    }
}

public final class ProgramPreviewController: ObservableObject, @unchecked Sendable {
    private enum Backend {
        case runtime(ActiveProgramRuntime)
        case standalone(ActiveProgramRenderer)
    }

    private let lock = NSLock()
    private let backend: Backend
    private let scheduler: any ProgramRuntimeScheduling
    private let renderQueue = DispatchQueue(label: "tokyo.kaito.ldtx.ProgramPreviewController.render", qos: .userInitiated)
    private var renderTimer: DispatchSourceTimer?
    private var framePacer = ProgramFramePacer()
    private var snapshot: ProgramPreviewSnapshot?
    private var latestRenderedFrame: ProgramFrame?
    private var sessionID = 0
    private var nextRenderedFrameID: UInt64 = 0
    private var isPreviewRunning = false

    public init(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
        backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil,
        scheduler: any ProgramRuntimeScheduling = SystemProgramRuntimeScheduler()
    ) {
        backend = .standalone(
            ActiveProgramRenderer(
                captureSessionCoordinator: captureSessionCoordinator,
                backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory
            )
        )
        self.scheduler = scheduler
    }

    public init(activeProgramRuntime: ActiveProgramRuntime) {
        backend = .runtime(activeProgramRuntime)
        scheduler = SystemProgramRuntimeScheduler()
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

    public func updateProgramPreferences(_ preferences: ProgramPreferences) {
        switch backend {
        case let .runtime(activeProgramRuntime):
            activeProgramRuntime.updateProgramPreferences(preferences)
        case let .standalone(previewRenderer):
            previewRenderer.updateProgramPreferences(preferences)
        }
    }

    public func start() {
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
        case let .standalone(previewRenderer):
            let currentSessionID: Int
            lock.lock()
            guard renderTimer == nil else {
                lock.unlock()
                return
            }
            sessionID += 1
            currentSessionID = sessionID
            let timer = DispatchSource.makeTimerSource(queue: renderQueue)
            timer.setEventHandler { [weak self] in
                self?.renderTick(sessionID: currentSessionID)
            }
            renderTimer = timer
            lock.unlock()

            renderQueue.async { [weak self, previewRenderer] in
                self?.framePacer = ProgramFramePacer()
                previewRenderer.beginSession(currentSessionID)
                timer.schedule(deadline: .now())
                timer.resume()
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
            renderTimer?.setEventHandler {}
            renderTimer?.cancel()
            renderTimer = nil
            latestRenderedFrame = nil
            lock.unlock()

            renderQueue.async {
                previewRenderer.endSession(currentSessionID)
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

    private func renderTick(sessionID: Int) {
        dispatchPrecondition(condition: .onQueue(renderQueue))
        guard case let .standalone(previewRenderer) = backend else {
            return
        }
        guard let timer = lock.withLock({ () -> DispatchSourceTimer? in
            guard self.sessionID == sessionID else { return nil }
            return renderTimer
        }) else {
            previewRenderer.endSession(sessionID)
            return
        }
        guard var snapshot = currentSnapshot() else {
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
            var frame = try previewRenderer.render(
                snapshot: snapshot,
                sessionID: sessionID,
                frameID: nextStandaloneFrameID()
            )
            if frame.presentationTime == nil,
               snapshot.programVideoPTSInputKey == nil {
                frame.presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
            }
            setLatestFrame(frame)
        } catch {
            if error is CancellationError {
                return
            }
            logProgramPreviewRenderFailed(error, snapshot: snapshot)
        }
        timer.schedule(deadline: .now())
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
