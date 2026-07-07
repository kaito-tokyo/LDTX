// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreMedia
import Foundation
import OSLog

public final class CameraCaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public typealias SampleHandler = @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void
    public typealias ConfigurationHandler = @Sendable (String) -> Void
    private static let preferredVideoPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private static let frameRateTolerance = 0.01
    private static let logger = Logger(
        subsystem: "tokyo.kaito.ldtx",
        category: "CameraCaptureService"
    )

    private let sessionQueue = DispatchQueue(label: "tokyo.kaito.ldtx.CameraCaptureService.session")
    private let sampleQueue = DispatchQueue(label: "tokyo.kaito.ldtx.CameraCaptureService.samples")

    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var sampleHandler: SampleHandler?

    public func availableCameras() -> [CameraCaptureSource] {
        Self.allVideoDevices().map(Self.source(from:))
    }

    public func availableAudioDevices() -> [AudioCaptureSource] {
        let devices = Self.audioDevices()
        return devices.map(Self.audioSource(from:))
    }

    public func startCameraCapture(
        cameraID: String,
        audioDeviceID: String? = nil,
        targetWidth: Int,
        targetHeight: Int,
        frameRate: Int,
        capturesAudio: Bool = true,
        configurationHandler: ConfigurationHandler? = nil,
        handler: @escaping SampleHandler
    ) async throws {
        guard await requestAccess(for: .video) else {
            throw CameraCaptureServiceError.cameraAccessDenied
        }
        if capturesAudio {
            guard await requestAccess(for: .audio) else {
                throw CameraCaptureServiceError.microphoneAccessDenied
            }
        }

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                do {
                    try self.configureAndStart(
                        cameraID: cameraID,
                        audioDeviceID: audioDeviceID,
                        targetWidth: targetWidth,
                        targetHeight: targetHeight,
                        frameRate: frameRate,
                        capturesAudio: capturesAudio,
                        configurationHandler: configurationHandler,
                        handler: handler
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func startAudioCapture(
        audioDeviceID: String? = nil,
        handler: @escaping SampleHandler
    ) async throws {
        guard await requestAccess(for: .audio) else {
            throw CameraCaptureServiceError.microphoneAccessDenied
        }

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                do {
                    try self.configureAndStartAudio(
                        audioDeviceID: audioDeviceID,
                        handler: handler
                    )
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

                self.session?.stopRunning()
                self.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
                self.audioOutput?.setSampleBufferDelegate(nil, queue: nil)
                self.session = nil
                self.videoOutput = nil
                self.audioOutput = nil
                self.sampleHandler = nil
                continuation.resume()
            }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            sampleHandler?(sampleBuffer, .video)
        } else if output === audioOutput {
            Self.logger.debug(
                "Delivered audio sample: pts=\(sampleBuffer.presentationTimeStamp.seconds, privacy: .public), samples=\(CMSampleBufferGetNumSamples(sampleBuffer), privacy: .public)"
            )
            sampleHandler?(sampleBuffer, .audio)
        }
    }

    private func configureAndStart(
        cameraID: String,
        audioDeviceID: String?,
        targetWidth: Int,
        targetHeight: Int,
        frameRate: Int,
        capturesAudio: Bool,
        configurationHandler: ConfigurationHandler?,
        handler: @escaping SampleHandler
    ) throws {
        session?.stopRunning()

        guard let camera = Self.allVideoDevices().first(where: { $0.uniqueID == cameraID }) else {
            throw CameraCaptureServiceError.cameraNotFound(cameraID)
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        if Self.bestFormat(
            for: camera,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            frameRate: Double(frameRate)
        ) != nil {
            configurationHandler?("Capture session preset left unchanged for explicit activeFormat: \(session.sessionPreset.rawValue).")
        } else {
            applyPreset(targetWidth: targetWidth, targetHeight: targetHeight, to: session, camera: camera)
            configurationHandler?("Capture session preset after fallback selection: \(session.sessionPreset.rawValue).")
        }

        let videoInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(videoInput) else {
            session.commitConfiguration()
            throw CameraCaptureServiceError.cannotAddVideoInput
        }
        session.addInput(videoInput)

        do {
            try configureFormat(
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                frameRate: frameRate,
                for: camera,
                configurationHandler: configurationHandler
            )
        } catch {
            session.commitConfiguration()
            throw error
        }

        if capturesAudio {
            let audioDevice: AVCaptureDevice?
            if let audioDeviceID {
                audioDevice = Self.audioDevices().first(where: { $0.uniqueID == audioDeviceID })
                if audioDevice == nil {
                    session.commitConfiguration()
                    throw CameraCaptureServiceError.audioDeviceNotFound(audioDeviceID)
                }
            } else {
                audioDevice = AVCaptureDevice.default(for: .audio)
            }

            guard let audioDevice else {
                session.commitConfiguration()
                throw CameraCaptureServiceError.cannotAddAudioInput
            }

            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            guard session.canAddInput(audioInput) else {
                session.commitConfiguration()
                throw CameraCaptureServiceError.cannotAddAudioInput
            }
            session.addInput(audioInput)
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard videoOutput.availableVideoPixelFormatTypes.contains(Self.preferredVideoPixelFormat) else {
            session.commitConfiguration()
            throw CameraCaptureServiceError.unsupportedVideoPixelFormat(Self.fourCC(Self.preferredVideoPixelFormat))
        }
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Self.preferredVideoPixelFormat
        ]
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw CameraCaptureServiceError.cannotAddVideoOutput
        }
        session.addOutput(videoOutput)
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)

        let audioOutput: AVCaptureAudioDataOutput?
        if capturesAudio {
            let output = AVCaptureAudioDataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw CameraCaptureServiceError.cannotAddAudioOutput
            }
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            audioOutput = output
        } else {
            audioOutput = nil
        }

        session.commitConfiguration()
        configurationHandler?("Capture session committed: preset=\(session.sessionPreset.rawValue), device=\(Self.activeVideoConfigurationSummary(for: camera)).")

        self.sampleHandler = handler
        self.session = session
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput

        session.startRunning()
        configurationHandler?("Capture session started: isRunning=\(session.isRunning), preset=\(session.sessionPreset.rawValue), device=\(Self.activeVideoConfigurationSummary(for: camera)).")
        do {
            try configureFormat(
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                frameRate: frameRate,
                for: camera,
                configurationHandler: configurationHandler
            )
            configurationHandler?("Capture device format re-applied after session start: \(Self.activeVideoConfigurationSummary(for: camera)).")
        } catch {
            configurationHandler?("Capture device format re-apply after session start failed: \(error.localizedDescription)")
        }
    }

    private func configureAndStartAudio(
        audioDeviceID: String?,
        handler: @escaping SampleHandler
    ) throws {
        session?.stopRunning()

        let audioDevice: AVCaptureDevice?
        if let audioDeviceID {
            audioDevice = Self.audioDevices().first(where: { $0.uniqueID == audioDeviceID })
            if audioDevice == nil {
                throw CameraCaptureServiceError.audioDeviceNotFound(audioDeviceID)
            }
        } else {
            audioDevice = AVCaptureDevice.default(for: .audio)
        }

        guard let audioDevice else {
            throw CameraCaptureServiceError.cannotAddAudioInput
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        guard session.canAddInput(audioInput) else {
            session.commitConfiguration()
            throw CameraCaptureServiceError.cannotAddAudioInput
        }
        session.addInput(audioInput)

        let audioOutput = AVCaptureAudioDataOutput()
        guard session.canAddOutput(audioOutput) else {
            session.commitConfiguration()
            throw CameraCaptureServiceError.cannotAddAudioOutput
        }
        session.addOutput(audioOutput)
        audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)

        session.commitConfiguration()

        sampleHandler = handler
        self.session = session
        videoOutput = nil
        self.audioOutput = audioOutput

        session.startRunning()
        Self.logger.notice(
            "Audio-only capture session started: device=\(audioDevice.uniqueID, privacy: .public), isRunning=\(session.isRunning, privacy: .public)"
        )
    }

    private func configureFormat(
        targetWidth: Int,
        targetHeight: Int,
        frameRate: Int,
        for camera: AVCaptureDevice,
        configurationHandler: ConfigurationHandler?
    ) throws {
        guard targetWidth > 0, targetHeight > 0, frameRate > 0 else { return }
        let requested = Double(frameRate)
        let format = Self.bestFormat(
            for: camera,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            frameRate: requested
        )

        let requestedDuration = format
            .flatMap { Self.nearestFrameRateRange($0, requestedFrameRate: requested).range?.minFrameDuration }
            ?? CMTime(value: 1, timescale: CMTimeScale(frameRate))

        if let format {
            configurationHandler?(
                "Requested capture device format: \(Self.captureFormatRawDescription(format)), requestedFrameRate=\(frameRate), requestedFrameDuration=\(Self.timeRawDescription(CMTime(value: 1, timescale: CMTimeScale(frameRate))))."
            )
        } else {
            configurationHandler?("No capture device format candidate found for \(targetWidth)x\(targetHeight)@\(frameRate)fps; keeping current activeFormat.")
        }

        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }

        if let format {
            camera.activeFormat = format
        }

        let nearestActiveFrameRate = Self.nearestFrameRateRange(camera.activeFormat, requestedFrameRate: requested)
        if let range = nearestActiveFrameRate.range {
            let duration = Self.preferredFrameDuration(for: nearestActiveFrameRate.frameRate, in: range, fallback: requestedDuration)
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
        } else {
            configurationHandler?("Active capture device format does not support \(frameRate)fps; frame duration was not changed.")
        }

        configurationHandler?("Applied capture device format: \(Self.activeVideoConfigurationRawDescription(for: camera)).")
    }

    private func applyPreset(targetWidth: Int, targetHeight: Int, to session: AVCaptureSession, camera: AVCaptureDevice) {
        let candidates: [AVCaptureSession.Preset]
        if targetHeight >= 2_160 || targetWidth >= 3_840 {
            candidates = [.hd4K3840x2160, .hd1920x1080, .hd1280x720, .high]
        } else if targetHeight >= 1_080 || targetWidth >= 1_920 {
            candidates = [.hd1920x1080, .hd1280x720, .high]
        } else if targetHeight >= 720 || targetWidth >= 1_280 {
            candidates = [.hd1280x720, .high]
        } else {
            candidates = [.medium, .high]
        }

        if let preset = candidates.first(where: { session.canSetSessionPreset($0) && camera.supportsSessionPreset($0) }) {
            session.sessionPreset = preset
        }
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

    private static func videoDevices(deviceTypes: [AVCaptureDevice.DeviceType]) -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private static func allVideoDevices() -> [AVCaptureDevice] {
        videoDevices(deviceTypes: [.external, .builtInWideAngleCamera])
    }

    private static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
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

    private static func format(
        _ format: AVCaptureDevice.Format,
        supportsFrameRate frameRate: Double
    ) -> Bool {
        nearestFrameRateRange(format, requestedFrameRate: frameRate).range != nil
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

    private static func source(from device: AVCaptureDevice) -> CameraCaptureSource {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return CameraCaptureSource(
            id: device.uniqueID,
            name: device.localizedName,
            deviceType: device.deviceType.rawValue,
            modelID: device.modelID,
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            isExternal: device.deviceType == .external,
            formatSummary: videoFormatSummary(for: device),
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

    private static func videoFormatSummary(for device: AVCaptureDevice) -> String {
        activeVideoConfigurationSummary(for: device)
    }

    private static func activeVideoConfigurationSummary(for device: AVCaptureDevice) -> String {
        let activeFormat = device.activeFormat
        let activeDimensions = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription)
        let activePixelFormat = CMFormatDescriptionGetMediaSubType(activeFormat.formatDescription)
        let activeRanges = frameRateRangesSummary(activeFormat.videoSupportedFrameRateRanges)
        let activeMinimumFrameDuration = frameDurationSummary(device.activeVideoMinFrameDuration)
        let activeMaximumFrameDuration = frameDurationSummary(device.activeVideoMaxFrameDuration)
        var bestDimensions: CMVideoDimensions?
        var bestPixelCount = 0
        var maximumFrameRate = 0.0
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixelCount = Int(dimensions.width) * Int(dimensions.height)
            if pixelCount > bestPixelCount {
                bestDimensions = dimensions
                bestPixelCount = pixelCount
            }
            for range in format.videoSupportedFrameRateRanges {
                maximumFrameRate = max(maximumFrameRate, range.maxFrameRate)
            }
        }
        let bestResolution = bestDimensions.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown"
        return "active=\(Int(activeDimensions.width))x\(Int(activeDimensions.height))/\(fourCC(activePixelFormat))/fps=\(activeRanges), activeFrameDuration=min:\(activeMinimumFrameDuration)/max:\(activeMaximumFrameDuration), max=\(bestResolution)@\(String(format: "%.2f", maximumFrameRate))"
    }

    private static func activeVideoConfigurationRawDescription(for device: AVCaptureDevice) -> String {
        let activeFormat = device.activeFormat
        let activeDimensions = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription)
        let activePixelFormat = CMFormatDescriptionGetMediaSubType(activeFormat.formatDescription)
        return [
            "activeWidth=\(activeDimensions.width)",
            "activeHeight=\(activeDimensions.height)",
            "activePixelFormat=\(activePixelFormat)",
            "activeVideoSupportedFrameRateRangeCount=\(activeFormat.videoSupportedFrameRateRanges.count)",
            "activeVideoMinFrameDuration=\(timeRawDescription(device.activeVideoMinFrameDuration))",
            "activeVideoMaxFrameDuration=\(timeRawDescription(device.activeVideoMaxFrameDuration))",
            "formatCount=\(device.formats.count)"
        ].joined(separator: ", ")
    }

    private static func captureFormatSummary(_ format: AVCaptureDevice.Format) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let ranges = frameRateRangesSummary(format.videoSupportedFrameRateRanges)
        return "\(Int(dimensions.width))x\(Int(dimensions.height))/\(fourCC(pixelFormat))/fps=\(ranges)"
    }

    private static func captureFormatRawDescription(_ format: AVCaptureDevice.Format) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return [
            "width=\(dimensions.width)",
            "height=\(dimensions.height)",
            "pixelFormat=\(pixelFormat)",
            "videoSupportedFrameRateRangeCount=\(format.videoSupportedFrameRateRanges.count)"
        ].joined(separator: ", ")
    }

    private static func audioFormatSummary(for device: AVCaptureDevice) -> String {
        let activeFormat = device.activeFormat
        let mediaSubType = CMFormatDescriptionGetMediaSubType(activeFormat.formatDescription)
        return "active=\(fourCC(mediaSubType)), formats=\(device.formats.count)"
    }

    private static func frameRateRangesSummary(_ ranges: [AVFrameRateRange]) -> String {
        ranges
            .map { range in
                let minimum = String(format: "%.2f", range.minFrameRate)
                let maximum = String(format: "%.2f", range.maxFrameRate)
                return minimum == maximum ? maximum : "\(minimum)-\(maximum)"
            }
            .joined(separator: "/")
    }

    private static func frameDurationSummary(_ duration: CMTime) -> String {
        guard duration.isNumeric else { return "invalid" }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return "0" }
        return String(format: "%.6fs", seconds)
    }

    private static func timeRawDescription(_ time: CMTime) -> String {
        "value=\(time.value)/timescale=\(time.timescale)/flags=\(time.flags.rawValue)/epoch=\(time.epoch)"
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
}
