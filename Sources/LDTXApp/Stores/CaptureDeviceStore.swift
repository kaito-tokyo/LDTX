// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCapture

struct CaptureDeviceStore {
    struct RefreshResult {
        var cameras: [CameraCaptureSource]
        var audioDevices: [AudioCaptureSource]
        var previousSelectedAudioDeviceID: String?
        var selectedAudioDeviceID: String?
        var preferredAudioDevice: AudioCaptureSource?

        var restoredSelectedAudioDevice: AudioCaptureSource? {
            guard let previousSelectedAudioDeviceID,
                  selectedAudioDeviceID == previousSelectedAudioDeviceID else {
                return nil
            }
            return audioDevices.first { $0.id == previousSelectedAudioDeviceID }
        }

        var didSelectFallbackForUnavailableStoredAudio: Bool {
            guard let previousSelectedAudioDeviceID else {
                return false
            }
            return !audioDevices.contains { $0.id == previousSelectedAudioDeviceID }
        }
    }

    private(set) var cameras: [CameraCaptureSource] = []
    private(set) var audioDevices: [AudioCaptureSource] = []
    private(set) var selectedAudioDeviceID: String?

    private let service: any CaptureDeviceService

    init(service: any CaptureDeviceService) {
        self.service = service
    }

    mutating func selectAudioDevice(id: String?) {
        selectedAudioDeviceID = id
    }

    mutating func reload() -> RefreshResult {
        let availableCameras = service.availableCameras()
        let availableAudioDevices = service.availableAudioDevices()
        let previousSelectedAudioDeviceID = selectedAudioDeviceID
        let preferredAudioDevice = Self.preferredElgatoNeoAudioDevice(in: availableAudioDevices)

        cameras = availableCameras
        audioDevices = availableAudioDevices
        if let selectedAudioDeviceID,
           availableAudioDevices.contains(where: { $0.id == selectedAudioDeviceID }) {
            self.selectedAudioDeviceID = selectedAudioDeviceID
        } else if let preferredAudioDevice {
            selectedAudioDeviceID = preferredAudioDevice.id
        } else {
            selectedAudioDeviceID = availableAudioDevices.first?.id
        }

        return RefreshResult(
            cameras: availableCameras,
            audioDevices: availableAudioDevices,
            previousSelectedAudioDeviceID: previousSelectedAudioDeviceID,
            selectedAudioDeviceID: selectedAudioDeviceID,
            preferredAudioDevice: preferredAudioDevice
        )
    }

    func containsCamera(id: String?) -> Bool {
        guard let id else {
            return false
        }
        return cameras.contains { $0.id == id }
    }

    static func redactedDeviceID(_ deviceID: String) -> String {
        guard deviceID.count > 12 else { return deviceID }
        return "...\(deviceID.suffix(12))"
    }

    private static func preferredElgatoNeoAudioDevice(in devices: [AudioCaptureSource]) -> AudioCaptureSource? {
        devices.first { source in
            source.isExternal && isElgatoNeoDevice(name: source.name, modelID: source.modelID)
        } ?? devices.first { source in
            source.isExternal && isElgatoDevice(name: source.name, modelID: source.modelID)
        }
    }

    private static func isElgatoNeoDevice(name: String, modelID: String) -> Bool {
        let haystack = "\(name) \(modelID)".lowercased()
        return haystack.contains("elgato") && haystack.contains("neo")
    }

    private static func isElgatoDevice(name: String, modelID: String) -> Bool {
        let haystack = "\(name) \(modelID)".lowercased()
        return haystack.contains("elgato")
    }
}
