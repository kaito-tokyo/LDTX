// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreMedia
import Foundation

public protocol CameraCaptureStreaming: Sendable {
    func startCameraCapture(
        cameraID: String,
        audioDeviceID: String?,
        targetWidth: Int,
        targetHeight: Int,
        frameRate: Int,
        capturesAudio: Bool,
        configurationHandler: (@Sendable (String) -> Void)?,
        handler: @escaping @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void
    ) async throws

    func stop() async
}

public final class CameraCaptureService: CameraCaptureStreaming, @unchecked Sendable {
    public typealias SampleHandler = @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void
    public typealias ConfigurationHandler = @Sendable (String) -> Void

    private static let registry = SharedCaptureSessionRegistry.shared

    private let stateLock = NSLock()
    private var subscriptionIDs: [UUID] = []

    public init() {}

    public func availableCameras() -> [CameraCaptureSource] {
        CaptureSessionManager().availableCameras()
    }

    public func availableAudioDevices() -> [AudioCaptureSource] {
        CaptureSessionManager().availableAudioDevices()
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
        guard availableCameras().contains(where: { $0.id == cameraID }) else {
            throw CameraCaptureServiceError.cameraNotFound(cameraID)
        }

        let videoDemand = SharedCaptureSessionVideoDemand(
            deviceID: cameraID,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            frameRate: frameRate
        )
        var demands: [SharedCaptureSessionSubscriptionDemand] = [
            SharedCaptureSessionSubscriptionDemand(video: videoDemand)
        ]

        if capturesAudio {
            let availableAudioDevices = availableAudioDevices()
            let resolvedAudioDeviceID = try Self.resolveAudioDeviceID(
                requestedAudioDeviceID: audioDeviceID,
                availableAudioDevices: availableAudioDevices
            )
            let captureManager = CaptureSessionManager()
            if captureManager.areLinked(videoDeviceID: cameraID, audioDeviceID: resolvedAudioDeviceID) {
                demands = [
                    SharedCaptureSessionSubscriptionDemand(
                        video: videoDemand,
                        audioDeviceID: resolvedAudioDeviceID
                    )
                ]
                configurationHandler?("Capture subscription prepared as one linked video/audio session.")
            } else {
                demands = [
                    SharedCaptureSessionSubscriptionDemand(video: videoDemand),
                    SharedCaptureSessionSubscriptionDemand(audioDeviceID: resolvedAudioDeviceID)
                ]
                configurationHandler?("Capture subscription prepared as separate video/audio sessions because devices are not linked.")
            }
        } else {
            configurationHandler?("Capture subscription prepared as a video-only session.")
        }

        try await replaceSubscriptions(with: demands, handler: handler)
    }

    public func startAudioCapture(
        audioDeviceID: String? = nil,
        handler: @escaping SampleHandler
    ) async throws {
        let resolvedAudioDeviceID = try Self.resolveAudioDeviceID(
            requestedAudioDeviceID: audioDeviceID,
            availableAudioDevices: availableAudioDevices()
        )
        try await replaceSubscriptions(
            with: [SharedCaptureSessionSubscriptionDemand(audioDeviceID: resolvedAudioDeviceID)],
            handler: handler
        )
    }

    public func stop() async {
        let ids = stateLock.withLock { () -> [UUID] in
            let ids = subscriptionIDs
            subscriptionIDs = []
            return ids
        }
        await Self.registry.unregister(ids: ids)
    }

    private func replaceSubscriptions(
        with demands: [SharedCaptureSessionSubscriptionDemand],
        handler: @escaping SampleHandler
    ) async throws {
        let previousIDs = stateLock.withLock { () -> [UUID] in
            let ids = subscriptionIDs
            subscriptionIDs = []
            return ids
        }
        do {
            let newIDs = try await Self.registry.replace(
                ids: previousIDs,
                with: demands.map { demand in
                    SharedCaptureSessionRegistry.PendingSubscription(
                        demand: demand,
                        handler: handler
                    )
                }
            )
            stateLock.withLock {
                subscriptionIDs = newIDs
            }
        } catch {
            throw Self.mapError(error, for: demands)
        }
    }

    private static func resolveAudioDeviceID(
        requestedAudioDeviceID: String?,
        availableAudioDevices: [AudioCaptureSource]
    ) throws -> String {
        if let requestedAudioDeviceID {
            guard availableAudioDevices.contains(where: { $0.id == requestedAudioDeviceID }) else {
                throw CameraCaptureServiceError.audioDeviceNotFound(requestedAudioDeviceID)
            }
            return requestedAudioDeviceID
        }

        guard let defaultAudioDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID,
              availableAudioDevices.contains(where: { $0.id == defaultAudioDeviceID }) else {
            throw CameraCaptureServiceError.cannotAddAudioInput
        }
        return defaultAudioDeviceID
    }

    private static func mapError(
        _ error: Error,
        for demands: [SharedCaptureSessionSubscriptionDemand]
    ) -> Error {
        if let error = error as? CameraCaptureServiceError {
            return error
        }
        guard let error = error as? CaptureSessionManagerError else {
            return error
        }

        switch error {
        case .cameraAccessDenied:
            return CameraCaptureServiceError.cameraAccessDenied
        case .microphoneAccessDenied:
            return CameraCaptureServiceError.microphoneAccessDenied
        case let .videoDeviceNotFound(cameraID):
            return CameraCaptureServiceError.cameraNotFound(cameraID)
        case let .audioDeviceNotFound(audioDeviceID):
            return CameraCaptureServiceError.audioDeviceNotFound(audioDeviceID)
        case let .cannotAddInput(deviceID):
            if demands.contains(where: { $0.audioDeviceID == deviceID }) {
                return CameraCaptureServiceError.cannotAddAudioInput
            }
            return CameraCaptureServiceError.cannotAddVideoInput
        case let .cannotAddOutput(sourceKey),
             let .cannotAddConnection(sourceKey),
             let .missingInputPort(sourceKey):
            if sourceKey.hasPrefix("audio:") {
                return CameraCaptureServiceError.cannotAddAudioOutput
            }
            return CameraCaptureServiceError.cannotAddVideoOutput
        case let .unsupportedVideoPixelFormat(format):
            return CameraCaptureServiceError.unsupportedVideoPixelFormat(format)
        case .videoDeviceNotAllowed,
             .audioDeviceNotAllowed,
             .invalidRequest:
            return error
        }
    }
}
