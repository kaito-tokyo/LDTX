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
        case .invalidRequest:
            "The capture session request is empty."
        }
    }
}

public final class CaptureSessionManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public typealias SampleHandler = @Sendable (CapturedSample) -> Void

    private static let preferredVideoPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private static let frameRateTolerance = 0.01
    private static let logger = Logger(
        subsystem: "tokyo.kaito.ldtx",
        category: "CaptureSessionManager"
    )

    private let allowedVideoDeviceIDs: Set<String>?
    private let allowedAudioDeviceIDs: Set<String>?
    private let sessionQueue = DispatchQueue(label: "tokyo.kaito.ldtx.CaptureSessionManager.session")
    private let sampleQueue = DispatchQueue(label: "tokyo.kaito.ldtx.CaptureSessionManager.samples")

    private var session: AVCaptureSession?
    private var outputsByID: [ObjectIdentifier: ManagedOutput] = [:]
    private var sampleHandler: SampleHandler?

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
        handler: @escaping SampleHandler
    ) async throws {
        guard !request.videoInputs.isEmpty || !request.audioInputs.isEmpty else {
            throw CaptureSessionManagerError.invalidRequest
        }
        if !request.videoInputs.isEmpty {
            guard await requestAccess(for: .video) else {
                throw CaptureSessionManagerError.cameraAccessDenied
            }
        }
        if !request.audioInputs.isEmpty {
            guard await requestAccess(for: .audio) else {
                throw CaptureSessionManagerError.microphoneAccessDenied
            }
        }

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                do {
                    try self.configureAndStart(request: request, handler: handler)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.stopOnSessionQueue()
                continuation.resume()
            }
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
        sampleHandler?(CapturedSample(
            sourceKey: managedOutput.sourceKey,
            deviceID: managedOutput.deviceID,
            kind: managedOutput.kind,
            sampleBuffer: sampleBuffer
        ))
    }

    private func configureAndStart(
        request: CaptureSessionRequest,
        handler: @escaping SampleHandler
    ) throws {
        stopOnSessionQueue()

        let session = AVCaptureSession()
        session.beginConfiguration()
        do {
            try configureVideoInputs(request.videoInputs, in: session)
            try configureAudioInputs(request.audioInputs, in: session)
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()

        sampleHandler = handler
        self.session = session
        session.startRunning()
        Self.logger.notice(
            "Capture session started: videoInputs=\(request.videoInputs.count, privacy: .public), audioInputs=\(request.audioInputs.count, privacy: .public), isRunning=\(session.isRunning, privacy: .public)"
        )
    }

    private func configureVideoInputs(
        _ requests: [CaptureSessionVideoRequest],
        in session: AVCaptureSession
    ) throws {
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
            let input = try AVCaptureDeviceInput(device: device)
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
            let input = try AVCaptureDeviceInput(device: device)
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
        outputsByID[ObjectIdentifier(output)] = ManagedOutput(
            sourceKey: sourceKey,
            deviceID: deviceID,
            kind: kind
        )
    }

    private func stopOnSessionQueue() {
        session?.stopRunning()
        outputsByID.removeAll(keepingCapacity: true)
        sampleHandler = nil
        session = nil
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
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

    private static func activeVideoConfigurationSummary(for device: AVCaptureDevice) -> String {
        let activeFormat = device.activeFormat
        let activeDimensions = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription)
        let activePixelFormat = CMFormatDescriptionGetMediaSubType(activeFormat.formatDescription)
        let activeRanges = activeFormat.videoSupportedFrameRateRanges
            .map { range in
                "\(String(format: "%.3f", range.minFrameRate))-\(String(format: "%.3f", range.maxFrameRate))fps"
            }
            .joined(separator: ",")
        return "\(Int(activeDimensions.width))x\(Int(activeDimensions.height)), pixelFormat=\(fourCC(activePixelFormat)), frameRates=[\(activeRanges)]"
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
    }
}
