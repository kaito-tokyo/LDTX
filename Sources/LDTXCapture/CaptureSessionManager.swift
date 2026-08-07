// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog

public struct CaptureSessionVideoRequest: Equatable, Sendable {
    public var sourceKey: String
    public var deviceID: String
    public var targetWidth: Int
    public var targetHeight: Int
    public var frameRate: Int

    public init(
        sourceKey: String,
        deviceID: String,
        targetWidth: Int,
        targetHeight: Int,
        frameRate: Int
    ) {
        self.sourceKey = sourceKey
        self.deviceID = deviceID
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.frameRate = frameRate
    }
}

public struct CaptureSessionAudioRequest: Equatable, Sendable {
    public var sourceKey: String
    public var deviceID: String

    public init(sourceKey: String, deviceID: String) {
        self.sourceKey = sourceKey
        self.deviceID = deviceID
    }
}

public struct CaptureSessionRequest: Equatable, Sendable {
    public var videoInputs: [CaptureSessionVideoRequest]
    public var audioInputs: [CaptureSessionAudioRequest]

    public init(
        videoInputs: [CaptureSessionVideoRequest] = [],
        audioInputs: [CaptureSessionAudioRequest] = []
    ) {
        self.videoInputs = videoInputs
        self.audioInputs = audioInputs
    }
}

public struct CapturedSample {
    public var sourceKey: String
    public var deviceID: String
    public var kind: CameraCaptureSampleKind
    public var sampleBuffer: CMSampleBuffer

    public init(
        sourceKey: String,
        deviceID: String,
        kind: CameraCaptureSampleKind,
        sampleBuffer: CMSampleBuffer
    ) {
        self.sourceKey = sourceKey
        self.deviceID = deviceID
        self.kind = kind
        self.sampleBuffer = sampleBuffer
    }
}

public enum CaptureSessionRuntimeFailure: Error, Sendable, Equatable {
    case audioFormatChanged(
        deviceID: String,
        previous: AudioStreamBasicDescription,
        current: AudioStreamBasicDescription
    )
    case deviceDisconnected(deviceID: String)
    case sessionRuntimeError(code: Int)
    case sessionInterrupted(reason: Int)
}

public enum CaptureSessionManagerError: Error, Equatable, LocalizedError {
    case cameraAccessDenied
    case microphoneAccessDenied
    case videoDeviceNotAllowed(String)
    case audioDeviceNotAllowed(String)
    case videoDeviceNotFound(String)
    case audioDeviceNotFound(String)
    case cannotAddInput(String)
    case cannotAddOutput(String)
    case cannotAddConnection(String)
    case missingInputPort(String)
    case unsupportedVideoPixelFormat(String)
    case audioFormatDidNotStabilize
    case invalidRequest

    public var errorDescription: String? {
        switch self {
        case .cameraAccessDenied:
            "Camera access was denied."
        case .microphoneAccessDenied:
            "Microphone access was denied."
        case let .videoDeviceNotAllowed(id):
            "The video device is not in the allowed capture device list: \(id)."
        case let .audioDeviceNotAllowed(id):
            "The audio device is not in the allowed capture device list: \(id)."
        case let .videoDeviceNotFound(id):
            "The video device could not be found: \(id)."
        case let .audioDeviceNotFound(id):
            "The audio device could not be found: \(id)."
        case let .cannotAddInput(id):
            "The capture input could not be added: \(id)."
        case let .cannotAddOutput(key):
            "The capture output could not be added: \(key)."
        case let .cannotAddConnection(key):
            "The capture connection could not be added: \(key)."
        case let .missingInputPort(key):
            "The capture input port could not be found: \(key)."
        case let .unsupportedVideoPixelFormat(format):
            "The capture video pixel format is not supported: \(format)."
        case .audioFormatDidNotStabilize:
            "The capture audio format did not stabilize during warm-up."
        case .invalidRequest:
            "The capture session request is empty."
        }
    }
}

public final class CaptureSessionManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public typealias SampleHandler = @Sendable (CapturedSample) -> Void
    public typealias FailureHandler = @Sendable (CaptureSessionRuntimeFailure) -> Void

    private static let preferredVideoPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private static let frameRateTolerance = 0.01
    private static let logger = Logger(
        subsystem: "tokyo.kaito.ldtx",
        category: "CaptureSessionManager"
    )
    private static let signpostLog = OSLog(
        subsystem: "tokyo.kaito.ldtx",
        category: "PointsOfInterest"
    )

    private let allowedVideoDeviceIDs: Set<String>?
    private let allowedAudioDeviceIDs: Set<String>?
    private let sessionQueue = DispatchQueue(label: "tokyo.kaito.ldtx.CaptureSessionManager.session")
    private let sampleQueue = DispatchQueue(label: "tokyo.kaito.ldtx.CaptureSessionManager.samples")
    private let startupLock = NSLock()

    private var session: AVCaptureSession?
    private var outputsByID: [ObjectIdentifier: ManagedOutput] = [:]
    private var sampleHandler: SampleHandler?
    private var failureHandler: FailureHandler?
    private var warmupGate = CaptureWarmupGate(requiredAudioDeviceIDs: [])
    private var startupCompletionHandler: (@Sendable (Result<Void, any Error>) -> Void)?
    private var notificationObservers: [NSObjectProtocol] = []
    private var activeDeviceIDs: Set<String> = []

    public init(
        allowedVideoDeviceIDs: Set<String>? = nil,
        allowedAudioDeviceIDs: Set<String>? = nil
    ) {
        self.allowedVideoDeviceIDs = allowedVideoDeviceIDs
        self.allowedAudioDeviceIDs = allowedAudioDeviceIDs
        super.init()
    }

    public func availableCameras() -> [CameraCaptureSource] {
        Self.allVideoDevices()
            .filter { allowedVideoDeviceIDs?.contains($0.uniqueID) ?? true }
            .map(Self.cameraSource(from:))
    }

    public func availableAudioDevices() -> [AudioCaptureSource] {
        Self.audioDevices()
            .filter { allowedAudioDeviceIDs?.contains($0.uniqueID) ?? true }
            .map(Self.audioSource(from:))
    }

    public func areLinked(videoDeviceID: String, audioDeviceID: String) -> Bool {
        guard let videoDevice = Self.allVideoDevices().first(where: { $0.uniqueID == videoDeviceID }),
              let audioDevice = Self.audioDevices().first(where: { $0.uniqueID == audioDeviceID }) else {
            return false
        }
        return Self.areLinked(videoDevice: videoDevice, audioDevice: audioDevice)
    }

    public func start(
        request: CaptureSessionRequest,
        handler: @escaping SampleHandler,
        failureHandler: @escaping FailureHandler = { _ in },
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        guard !request.videoInputs.isEmpty || !request.audioInputs.isEmpty else {
            completionHandler(.failure(CaptureSessionManagerError.invalidRequest))
            return
        }
        requestRequiredAccess(for: request) { [weak self] result in
            guard let self else {
                completionHandler(.success(()))
                return
            }
            switch result {
            case .success:
                self.startOnSessionQueue(
                    request: request,
                    handler: handler,
                    failureHandler: failureHandler,
                    completionHandler: completionHandler
                )
            case let .failure(error):
                completionHandler(.failure(error))
            }
        }
    }

    public func stop(completionHandler: @escaping @Sendable () -> Void = {}) {
        sessionQueue.async { [weak self] in
            guard let self else {
                completionHandler()
                return
            }
            self.stopOnSessionQueue()
            completionHandler()
        }
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let managedOutput = outputsByID[ObjectIdentifier(output)] else {
            return
        }
        managedOutput.videoTimingDiagnostics?.record(sampleBuffer: sampleBuffer)
        switch warmupGate.observe(
            audioFormat: Self.audioStreamBasicDescription(from: sampleBuffer, kind: managedOutput.kind),
            deviceID: managedOutput.deviceID,
            kind: managedOutput.kind
        ) {
        case .skipped:
            return
        case .opened:
            resumeStartup()
            return
        case .accepted:
            break
        case let .audioFormatChanged(deviceID, previous, current):
            failureHandler?(.audioFormatChanged(
                deviceID: deviceID,
                previous: previous,
                current: current
            ))
            return
        }
        sampleHandler?(CapturedSample(
            sourceKey: managedOutput.sourceKey,
            deviceID: managedOutput.deviceID,
            kind: managedOutput.kind,
            sampleBuffer: sampleBuffer
        ))
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        outputsByID[ObjectIdentifier(output)]?.videoTimingDiagnostics?.recordDroppedSample()
    }

    private func configureAndStart(
        request: CaptureSessionRequest,
        handler: @escaping SampleHandler,
        failureHandler: @escaping FailureHandler
    ) throws {
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "Capture Session Start", signpostID: signpostID)
        defer {
            os_signpost(.end, log: Self.signpostLog, name: "Capture Session Start", signpostID: signpostID)
        }

        stopOnSessionQueue()
        prepareSampleDeliveryState(
            requiredAudioDeviceIDs: Set(request.audioInputs.map(\.deviceID)),
            failureHandler: failureHandler
        )

        let session = AVCaptureSession()
        session.beginConfiguration()
        let configuredVideoInputs: [ConfiguredVideoInput]
        do {
            configuredVideoInputs = try configureVideoInputs(request.videoInputs, in: session)
            try configureAudioInputs(request.audioInputs, in: session)
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
        self.session = session
        observeRuntimeFailures(for: session, deviceIDs: Set(
            request.videoInputs.map(\.deviceID) + request.audioInputs.map(\.deviceID)
        ))
        do {
            try CaptureSessionStartupSequence.run(
                start: {
                    session.startRunning()
                },
                reapplyVideoConfiguration: {
                    try self.reapplyVideoFormats(configuredVideoInputs)
                },
                enableSampleDelivery: {
                    self.sampleQueue.sync {
                        self.sampleHandler = handler
                    }
                }
            )
        } catch {
            session.stopRunning()
            disableSampleBufferDelegates(for: session)
            removeRuntimeFailureObservers()
            clearSampleDeliveryState()
            self.session = nil
            throw error
        }
        Self.logger.notice(
            "Capture session started: videoInputs=\(request.videoInputs.count, privacy: .public), audioInputs=\(request.audioInputs.count, privacy: .public), videoDevices=\(Self.describeVideoInputs(request.videoInputs), privacy: .public), audioDevices=\(Self.describeAudioInputs(request.audioInputs), privacy: .public), isRunning=\(session.isRunning, privacy: .public)"
        )
    }

    private func configureVideoInputs(
        _ requests: [CaptureSessionVideoRequest],
        in session: AVCaptureSession
    ) throws -> [ConfiguredVideoInput] {
        var configuredInputs: [ConfiguredVideoInput] = []
        for request in requests {
            if let allowedVideoDeviceIDs, !allowedVideoDeviceIDs.contains(request.deviceID) {
                throw CaptureSessionManagerError.videoDeviceNotAllowed(request.deviceID)
            }
            guard let device = Self.allVideoDevices().first(where: { $0.uniqueID == request.deviceID }) else {
                throw CaptureSessionManagerError.videoDeviceNotFound(request.deviceID)
            }
            try configureFormat(
                targetWidth: request.targetWidth,
                targetHeight: request.targetHeight,
                frameRate: request.frameRate,
                for: device
            )
            let input = try Self.makeDeviceInput(for: device)
            guard session.canAddInput(input) else {
                throw CaptureSessionManagerError.cannotAddInput(request.deviceID)
            }
            session.addInputWithNoConnections(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            guard output.availableVideoPixelFormatTypes.contains(Self.preferredVideoPixelFormat) else {
                throw CaptureSessionManagerError.unsupportedVideoPixelFormat(Self.fourCC(Self.preferredVideoPixelFormat))
            }
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Self.preferredVideoPixelFormat
            ]
            guard session.canAddOutput(output) else {
                throw CaptureSessionManagerError.cannotAddOutput(request.sourceKey)
            }
            session.addOutputWithNoConnections(output)
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            try connect(
                input: input,
                mediaType: .video,
                output: output,
                sourceKey: request.sourceKey,
                deviceID: request.deviceID,
                kind: .video,
                in: session
            )
            configuredInputs.append(ConfiguredVideoInput(request: request, device: device))
        }
        return configuredInputs
    }

    private func reapplyVideoFormats(_ inputs: [ConfiguredVideoInput]) throws {
        for input in inputs {
            try configureFormat(
                targetWidth: input.request.targetWidth,
                targetHeight: input.request.targetHeight,
                frameRate: input.request.frameRate,
                for: input.device
            )
            Self.logger.notice(
                "Reapplied video configuration after capture session start: device=\(input.request.deviceID, privacy: .public), requested=\(input.request.targetWidth, privacy: .public)x\(input.request.targetHeight, privacy: .public)/\(input.request.frameRate, privacy: .public), active=\(Self.activeVideoConfigurationSummary(for: input.device), privacy: .public)"
            )
        }
    }

    private func configureAudioInputs(
        _ requests: [CaptureSessionAudioRequest],
        in session: AVCaptureSession
    ) throws {
        for request in requests {
            if let allowedAudioDeviceIDs, !allowedAudioDeviceIDs.contains(request.deviceID) {
                throw CaptureSessionManagerError.audioDeviceNotAllowed(request.deviceID)
            }
            guard let device = Self.audioDevices().first(where: { $0.uniqueID == request.deviceID }) else {
                throw CaptureSessionManagerError.audioDeviceNotFound(request.deviceID)
            }
            let input = try Self.makeDeviceInput(for: device)
            guard session.canAddInput(input) else {
                throw CaptureSessionManagerError.cannotAddInput(request.deviceID)
            }
            session.addInputWithNoConnections(input)

            let output = AVCaptureAudioDataOutput()
            guard session.canAddOutput(output) else {
                throw CaptureSessionManagerError.cannotAddOutput(request.sourceKey)
            }
            session.addOutputWithNoConnections(output)
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            try connect(
                input: input,
                mediaType: .audio,
                output: output,
                sourceKey: request.sourceKey,
                deviceID: request.deviceID,
                kind: .audio,
                in: session
            )
        }
    }

    private func connect(
        input: AVCaptureDeviceInput,
        mediaType: AVMediaType,
        output: AVCaptureOutput,
        sourceKey: String,
        deviceID: String,
        kind: CameraCaptureSampleKind,
        in session: AVCaptureSession
    ) throws {
        guard let port = input.ports.first(where: { $0.mediaType == mediaType }) else {
            throw CaptureSessionManagerError.missingInputPort(sourceKey)
        }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else {
            throw CaptureSessionManagerError.cannotAddConnection(sourceKey)
        }
        session.addConnection(connection)
        sampleQueue.sync {
            outputsByID[ObjectIdentifier(output)] = ManagedOutput(
                sourceKey: sourceKey,
                deviceID: deviceID,
                kind: kind,
                videoTimingDiagnostics: kind == .video
                    ? VideoTimingDiagnostics(deviceID: deviceID)
                    : nil
            )
        }
    }

    private func stopOnSessionQueue() {
        if let session {
            let outputs = sampleQueue.sync { Array(self.outputsByID.values) }
            let videoOutputCount = outputs.filter { $0.kind == .video }.count
            let audioOutputCount = outputs.filter { $0.kind == .audio }.count
            Self.logger.notice(
                "Stopping capture session: videoOutputs=\(videoOutputCount, privacy: .public), audioOutputs=\(audioOutputCount, privacy: .public), routes=\(Self.describeManagedOutputs(outputs), privacy: .public), wasRunning=\(session.isRunning, privacy: .public)"
            )
            disableSampleBufferDelegates(for: session)
        }
        session?.stopRunning()
        removeRuntimeFailureObservers()
        clearSampleDeliveryState()
        resumeStartup(throwing: CancellationError())
        session = nil
    }

    private func observeRuntimeFailures(for session: AVCaptureSession, deviceIDs: Set<String>) {
        removeRuntimeFailureObservers()
        activeDeviceIDs = deviceIDs
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: nil
            ) { [weak self] notification in
                guard let self else { return }
                let code = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? -1
                sessionQueue.async { [weak self] in
                    guard let self else { return }
                    switch CaptureSessionRuntimeFailurePolicy.action(
                        errorCode: code,
                        observedSessionIsCurrent: self.session === session
                    ) {
                    case .discard:
                        return
                    case .restart:
                        guard !session.isRunning else { return }
                        Self.logger.notice(
                            "Capture media services were reset; restarting the current session"
                        )
                        session.startRunning()
                    case .report:
                        self.reportRuntimeFailure(.sessionRuntimeError(code: code))
                    }
                }
            },
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let device = notification.object as? AVCaptureDevice else { return }
                guard let self else { return }
                sessionQueue.async { [weak self] in
                    guard self?.activeDeviceIDs.contains(device.uniqueID) == true else { return }
                    self?.reportRuntimeFailure(.deviceDisconnected(deviceID: device.uniqueID))
                }
            },
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil
            ) { _ in
                Self.logger.notice("Capture session was interrupted; waiting for interruption end")
            },
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                sessionQueue.async { [weak self] in
                    guard let self, self.session === session, !session.isRunning else { return }
                    Self.logger.notice("Capture session interruption ended; resuming capture")
                    session.startRunning()
                }
            }
        ]
    }

    private func removeRuntimeFailureObservers() {
        let center = NotificationCenter.default
        notificationObservers.forEach(center.removeObserver)
        notificationObservers = []
        activeDeviceIDs = []
    }

    private func reportRuntimeFailure(_ failure: CaptureSessionRuntimeFailure) {
        let handler = sampleQueue.sync { failureHandler }
        handler?(failure)
    }

    private func prepareSampleDeliveryState(
        requiredAudioDeviceIDs: Set<String>,
        failureHandler: @escaping FailureHandler
    ) {
        sampleQueue.sync {
            warmupGate = CaptureWarmupGate(requiredAudioDeviceIDs: requiredAudioDeviceIDs)
            self.failureHandler = failureHandler
        }
    }

    private func clearSampleDeliveryState() {
        sampleQueue.sync {
            outputsByID.removeAll(keepingCapacity: true)
            sampleHandler = nil
            failureHandler = nil
            warmupGate = CaptureWarmupGate(requiredAudioDeviceIDs: [])
        }
    }

    private func disableSampleBufferDelegates(for session: AVCaptureSession) {
        for output in session.outputs {
            if let videoOutput = output as? AVCaptureVideoDataOutput {
                videoOutput.setSampleBufferDelegate(nil, queue: nil)
            } else if let audioOutput = output as? AVCaptureAudioDataOutput {
                audioOutput.setSampleBufferDelegate(nil, queue: nil)
            }
        }
    }

    private func startOnSessionQueue(
        request: CaptureSessionRequest,
        handler: @escaping SampleHandler,
        failureHandler: @escaping FailureHandler,
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self else {
                completionHandler(.success(()))
                return
            }
            do {
                try self.configureAndStart(
                    request: request,
                    handler: handler,
                    failureHandler: failureHandler
                )
                self.startupLock.withLock {
                    self.startupCompletionHandler = completionHandler
                }
                if self.warmupGate.isWarmedUp {
                    self.resumeStartup()
                } else {
                    self.sessionQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.failStartupIfPending(CaptureSessionManagerError.audioFormatDidNotStabilize)
                    }
                }
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    private func resumeStartup(throwing error: (any Error)? = nil) {
        let completionHandler = startupLock.withLock { () -> (@Sendable (Result<Void, any Error>) -> Void)? in
            let completionHandler = startupCompletionHandler
            startupCompletionHandler = nil
            return completionHandler
        }
        if let error {
            completionHandler?(.failure(error))
        } else {
            completionHandler?(.success(()))
        }
    }

    private func failStartupIfPending(_ error: any Error) {
        let completionHandler = startupLock.withLock { () -> (@Sendable (Result<Void, any Error>) -> Void)? in
            let completionHandler = startupCompletionHandler
            startupCompletionHandler = nil
            return completionHandler
        }
        guard let completionHandler else { return }
        stopOnSessionQueue()
        Self.logger.error("Capture session warm-up failed: \(error.localizedDescription, privacy: .public)")
        completionHandler(.failure(error))
    }

    private static func audioStreamBasicDescription(
        from sampleBuffer: CMSampleBuffer,
        kind: CameraCaptureSampleKind
    ) -> AudioStreamBasicDescription? {
        guard kind == .audio,
              let formatDescription = sampleBuffer.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        return description.pointee
    }

    private func requestAccess(
        for mediaType: AVMediaType,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            completionHandler(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType, completionHandler: completionHandler)
        case .denied, .restricted:
            completionHandler(false)
        @unknown default:
            completionHandler(false)
        }
    }

    private func requestRequiredAccess(
        for request: CaptureSessionRequest,
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        let requestAudioAccess: @Sendable () -> Void = { [weak self] in
            guard !request.audioInputs.isEmpty else {
                completionHandler(.success(()))
                return
            }
            guard let self else {
                completionHandler(.success(()))
                return
            }
            self.requestAccess(for: .audio) { granted in
                completionHandler(granted
                    ? .success(())
                    : .failure(CaptureSessionManagerError.microphoneAccessDenied))
            }
        }

        guard !request.videoInputs.isEmpty else {
            requestAudioAccess()
            return
        }
        requestAccess(for: .video) { granted in
            guard granted else {
                completionHandler(.failure(CaptureSessionManagerError.cameraAccessDenied))
                return
            }
            requestAudioAccess()
        }
    }

    private func configureFormat(
        targetWidth: Int,
        targetHeight: Int,
        frameRate: Int,
        for camera: AVCaptureDevice
    ) throws {
        guard targetWidth > 0, targetHeight > 0, frameRate > 0 else { return }
        let requested = Double(frameRate)
        let selectedFormat = Self.bestFormat(
            for: camera,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            frameRate: requested
        )
        let fallbackDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let requestedDuration = selectedFormat
            .flatMap { Self.nearestFrameRateRange($0, requestedFrameRate: requested).range?.minFrameDuration }
            ?? fallbackDuration

        try AVCaptureDeviceConfigurationGate.withLock {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }

            if let selectedFormat {
                camera.activeFormat = selectedFormat
            }
            let nearestActiveFrameRate = Self.nearestFrameRateRange(camera.activeFormat, requestedFrameRate: requested)
            if let range = nearestActiveFrameRate.range {
                let duration = Self.preferredFrameDuration(
                    for: nearestActiveFrameRate.frameRate,
                    in: range,
                    fallback: requestedDuration
                )
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = duration
            }
        }
    }

    private static func allVideoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    private static func areLinked(videoDevice: AVCaptureDevice, audioDevice: AVCaptureDevice) -> Bool {
        videoDevice.uniqueID == audioDevice.uniqueID
            || videoDevice.linkedDevices.contains(where: { $0.uniqueID == audioDevice.uniqueID })
            || audioDevice.linkedDevices.contains(where: { $0.uniqueID == videoDevice.uniqueID })
    }

    private static func describeVideoInputs(_ requests: [CaptureSessionVideoRequest]) -> String {
        if requests.isEmpty {
            return "none"
        }
        return requests.map {
            "\($0.deviceID)@\($0.targetWidth)x\($0.targetHeight)/\($0.frameRate)"
        }.joined(separator: ",")
    }

    private static func describeAudioInputs(_ requests: [CaptureSessionAudioRequest]) -> String {
        if requests.isEmpty {
            return "none"
        }
        return requests.map(\.deviceID).joined(separator: ",")
    }

    private static func describeManagedOutputs(_ outputs: [ManagedOutput]) -> String {
        let descriptions = outputs.map {
            "\($0.kind == .video ? "video" : "audio"):\($0.deviceID)"
        }
        if descriptions.isEmpty {
            return "none"
        }
        return descriptions.sorted().joined(separator: ",")
    }

    private static func cameraSource(from device: AVCaptureDevice) -> CameraCaptureSource {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return CameraCaptureSource(
            id: device.uniqueID,
            name: device.localizedName,
            deviceType: device.deviceType.rawValue,
            modelID: device.modelID,
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            isExternal: device.deviceType == .external,
            formatSummary: activeVideoConfigurationSummary(for: device),
            linkedDeviceIDs: device.linkedDevices.map(\.uniqueID)
        )
    }

    private static func audioSource(from device: AVCaptureDevice) -> AudioCaptureSource {
        AudioCaptureSource(
            id: device.uniqueID,
            name: device.localizedName,
            deviceType: device.deviceType.rawValue,
            modelID: device.modelID,
            isExternal: device.deviceType == .external,
            formatSummary: audioFormatSummary(for: device),
            linkedDeviceIDs: device.linkedDevices.map(\.uniqueID)
        )
    }

    private static func bestFormat(
        for camera: AVCaptureDevice,
        targetWidth: Int,
        targetHeight: Int,
        frameRate: Double
    ) -> AVCaptureDevice.Format? {
        camera.formats
            .filter {
                format($0, matchesWidth: targetWidth, height: targetHeight, pixelFormat: preferredVideoPixelFormat)
            }
            .min { lhs, rhs in
                let lhsDistance = nearestFrameRateRange(lhs, requestedFrameRate: frameRate).distance
                let rhsDistance = nearestFrameRateRange(rhs, requestedFrameRate: frameRate).distance
                if abs(lhsDistance - rhsDistance) <= frameRateTolerance {
                    return maxFrameRate(lhs) > maxFrameRate(rhs)
                }
                return lhsDistance < rhsDistance
            }
    }

    private static func format(
        _ format: AVCaptureDevice.Format,
        matchesWidth targetWidth: Int,
        height targetHeight: Int,
        pixelFormat targetPixelFormat: OSType
    ) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return Int(dimensions.width) == targetWidth
            && Int(dimensions.height) == targetHeight
            && CMFormatDescriptionGetMediaSubType(format.formatDescription) == targetPixelFormat
    }

    private static func nearestFrameRateRange(
        _ format: AVCaptureDevice.Format,
        requestedFrameRate: Double
    ) -> (range: AVFrameRateRange?, frameRate: Double, distance: Double) {
        let candidates = format.videoSupportedFrameRateRanges.map { range in
            let selectedFrameRate: Double
            if requestedFrameRate < range.minFrameRate {
                selectedFrameRate = range.minFrameRate
            } else if requestedFrameRate > range.maxFrameRate {
                selectedFrameRate = range.maxFrameRate
            } else if abs(range.minFrameRate - range.maxFrameRate) <= frameRateTolerance {
                selectedFrameRate = range.maxFrameRate
            } else {
                selectedFrameRate = requestedFrameRate
            }
            return (range: range, frameRate: selectedFrameRate, distance: abs(selectedFrameRate - requestedFrameRate))
        }
        return candidates.min { lhs, rhs in
            if abs(lhs.distance - rhs.distance) <= frameRateTolerance {
                return lhs.frameRate > rhs.frameRate
            }
            return lhs.distance < rhs.distance
        } ?? (nil, 0, Double.greatestFiniteMagnitude)
    }

    private static func preferredFrameDuration(
        for frameRate: Double,
        in range: AVFrameRateRange,
        fallback: CMTime
    ) -> CMTime {
        if abs(range.minFrameRate - range.maxFrameRate) <= frameRateTolerance {
            return range.minFrameDuration
        }
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
        return duration.isValid ? duration : fallback
    }

    private static func maxFrameRate(_ format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    private static func makeDeviceInput(for device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        try AVCaptureDeviceConfigurationGate.withLock {
            try AVCaptureDeviceInput(device: device)
        }
    }

    private static func activeVideoConfigurationSummary(for device: AVCaptureDevice) -> String {
        let activeFormat = device.activeFormat
        let activeDimensions = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription)
        let activePixelFormat = CMFormatDescriptionGetMediaSubType(activeFormat.formatDescription)
        let activeRanges = activeFormat.videoSupportedFrameRateRanges
            .map { range in
                "\(String(format: "%.3f", range.minFrameRate))-\(String(format: "%.3f", range.maxFrameRate))fps"
            }
            .joined(separator: ",")
        return "\(Int(activeDimensions.width))x\(Int(activeDimensions.height)), pixelFormat=\(fourCC(activePixelFormat)), frameRates=[\(activeRanges)], activeMinFPS=\(frameRateDescription(for: device.activeVideoMinFrameDuration)), activeMaxFPS=\(frameRateDescription(for: device.activeVideoMaxFrameDuration))"
    }

    private static func frameRateDescription(for duration: CMTime) -> String {
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { return "invalid" }
        return String(format: "%.3f", 1 / seconds)
    }

    private static func audioFormatSummary(for device: AVCaptureDevice) -> String {
        let formatDescription = device.activeFormat.formatDescription
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
        if let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee {
            return "format=\(fourCC(mediaSubType)), sampleRate=\(streamDescription.mSampleRate), channels=\(streamDescription.mChannelsPerFrame)"
        }
        return "format=\(fourCC(mediaSubType))"
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let scalarValues = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        let scalars = scalarValues.map { byte -> UnicodeScalar in
            if byte >= 32 && byte <= 126, let scalar = UnicodeScalar(Int(byte)) {
                return scalar
            }
            return "."
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private struct ManagedOutput {
        var sourceKey: String
        var deviceID: String
        var kind: CameraCaptureSampleKind
        var videoTimingDiagnostics: VideoTimingDiagnostics?
    }

    private struct ConfiguredVideoInput {
        var request: CaptureSessionVideoRequest
        var device: AVCaptureDevice
    }
}

private final class VideoTimingDiagnostics: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "tokyo.kaito.ldtx",
        category: "CaptureSessionManager"
    )
    private let deviceID: String
    private var sampleCount = 0
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var maximumGapSeconds = 0.0
    private var droppedSampleCount = 0

    init(deviceID: String) {
        self.deviceID = deviceID
    }

    func record(sampleBuffer: CMSampleBuffer) {
        let presentationTime = sampleBuffer.presentationTimeStamp
        guard presentationTime.isValid else { return }
        if firstPresentationTime == nil {
            firstPresentationTime = presentationTime
        }
        if let lastPresentationTime {
            let gap = CMTimeSubtract(presentationTime, lastPresentationTime).seconds
            if gap.isFinite, gap > maximumGapSeconds {
                maximumGapSeconds = gap
            }
        }
        lastPresentationTime = presentationTime
        sampleCount += 1

        guard sampleCount >= 120,
              let firstPresentationTime,
              let lastPresentationTime else {
            return
        }
        let span = CMTimeSubtract(lastPresentationTime, firstPresentationTime).seconds
        let measuredFrameRate = span.isFinite && span > 0
            ? Double(sampleCount - 1) / span
            : 0
        Self.logger.notice(
            "Capture video timing: device=\(self.deviceID, privacy: .public), samples=\(self.sampleCount, privacy: .public), measuredFPS=\(measuredFrameRate, format: .fixed(precision: 3), privacy: .public), maxGapMilliseconds=\(self.maximumGapSeconds * 1_000, format: .fixed(precision: 3), privacy: .public), droppedSamples=\(self.droppedSampleCount, privacy: .public)"
        )
        sampleCount = 1
        self.firstPresentationTime = lastPresentationTime
        maximumGapSeconds = 0
        droppedSampleCount = 0
    }

    func recordDroppedSample() {
        droppedSampleCount += 1
    }
}

enum CaptureSessionRuntimeFailureAction: Equatable {
    case discard
    case restart
    case report
}

enum CaptureSessionRuntimeFailurePolicy {
    // AVErrorMediaServicesWereReset in AVFoundation/AVError.h. The macOS Swift
    // overlay does not expose a named AVError.Code case for this value.
    static let mediaServicesWereResetErrorCode = -11_819

    static func action(
        errorCode: Int,
        observedSessionIsCurrent: Bool
    ) -> CaptureSessionRuntimeFailureAction {
        guard observedSessionIsCurrent else { return .discard }
        if errorCode == mediaServicesWereResetErrorCode {
            return .restart
        }
        return .report
    }
}

enum CaptureSessionStartupSequence {
    static func run(
        start: () -> Void,
        reapplyVideoConfiguration: () throws -> Void,
        enableSampleDelivery: () -> Void
    ) rethrows {
        start()
        try reapplyVideoConfiguration()
        enableSampleDelivery()
    }
}
