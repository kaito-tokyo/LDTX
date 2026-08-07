// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import AudioToolbox
import Testing
@testable import LDTXCapture

struct SharedCaptureSessionPlannerTests {
    @Test func deviceFailureOnlyTargetsSubscriptionsUsingThatDevice() {
        let cameraSubscription = UUID()
        let microphoneSubscription = UUID()
        let routes = [
            cameraSubscription: Set([
                SharedCaptureSessionRouteInterest(deviceID: "camera-a", kind: .video)
            ]),
            microphoneSubscription: Set([
                SharedCaptureSessionRouteInterest(deviceID: "mic-a", kind: .audio)
            ]),
        ]

        #expect(SharedCaptureFailureRouter.subscriptionIDs(
            for: .deviceDisconnected(deviceID: "camera-a"),
            routesBySubscriptionID: routes
        ) == [cameraSubscription])
        #expect(SharedCaptureFailureRouter.subscriptionIDs(
            for: .audioFormatChanged(
                deviceID: "mic-a",
                previous: AudioStreamBasicDescription(),
                current: AudioStreamBasicDescription()
            ),
            routesBySubscriptionID: routes
        ) == [microphoneSubscription])
        #expect(SharedCaptureFailureRouter.subscriptionIDs(
            for: .sessionRuntimeError(code: -1),
            routesBySubscriptionID: routes
        ) == [cameraSubscription, microphoneSubscription])
    }

    @Test func linkedVideoAndAudioShareOneSessionPlan() {
        let plans = SharedCaptureSessionPlanner.makePlans(
            subscriptions: [
                UUID(): SharedCaptureSessionSubscriptionDemand(
                    video: SharedCaptureSessionVideoDemand(
                        deviceID: "camera-a",
                        targetWidth: 1280,
                        targetHeight: 720,
                        frameRate: 30
                    )
                ),
                UUID(): SharedCaptureSessionSubscriptionDemand(audioDeviceID: "mic-a")
            ],
            cameras: [
                CameraCaptureSource(
                    id: "camera-a",
                    name: "Camera A",
                    deviceType: "external",
                    modelID: "camera-a",
                    width: 1280,
                    height: 720,
                    isExternal: true,
                    formatSummary: "",
                    linkedDeviceIDs: ["mic-a"]
                )
            ],
            audioDevices: [
                AudioCaptureSource(
                    id: "mic-a",
                    name: "Mic A",
                    deviceType: "microphone",
                    modelID: "mic-a",
                    isExternal: true,
                    formatSummary: "",
                    linkedDeviceIDs: ["camera-a"]
                )
            ]
        )

        #expect(plans.count == 1)
        #expect(plans[0].request.videoInputs.map(\.deviceID) == ["camera-a"])
        #expect(plans[0].request.audioInputs.map(\.deviceID) == ["mic-a"])
        #expect(plans[0].key.groupedDeviceIDs == ["camera-a", "mic-a"])
    }

    @Test func unlinkedDevicesStayInSeparateSessions() {
        let plans = SharedCaptureSessionPlanner.makePlans(
            subscriptions: [
                UUID(): SharedCaptureSessionSubscriptionDemand(
                    video: SharedCaptureSessionVideoDemand(
                        deviceID: "camera-a",
                        targetWidth: 1280,
                        targetHeight: 720,
                        frameRate: 30
                    )
                ),
                UUID(): SharedCaptureSessionSubscriptionDemand(audioDeviceID: "mic-b")
            ],
            cameras: [
                CameraCaptureSource(
                    id: "camera-a",
                    name: "Camera A",
                    deviceType: "external",
                    modelID: "camera-a",
                    width: 1280,
                    height: 720,
                    isExternal: true,
                    formatSummary: ""
                )
            ],
            audioDevices: [
                AudioCaptureSource(
                    id: "mic-b",
                    name: "Mic B",
                    deviceType: "microphone",
                    modelID: "mic-b",
                    isExternal: true,
                    formatSummary: ""
                )
            ]
        )

        #expect(plans.count == 2)
        #expect(
            plans.map {
                "\($0.request.videoInputs.map(\.deviceID).joined(separator: ","))|\($0.request.audioInputs.map(\.deviceID).joined(separator: ","))"
            }.sorted() == ["camera-a|", "|mic-b"]
        )
    }

    @Test func aggregatesVideoDemandToHighestRequestedConfiguration() {
        let plans = SharedCaptureSessionPlanner.makePlans(
            subscriptions: [
                UUID(): SharedCaptureSessionSubscriptionDemand(
                    video: SharedCaptureSessionVideoDemand(
                        deviceID: "camera-a",
                        targetWidth: 1280,
                        targetHeight: 720,
                        frameRate: 30
                    )
                ),
                UUID(): SharedCaptureSessionSubscriptionDemand(
                    video: SharedCaptureSessionVideoDemand(
                        deviceID: "camera-a",
                        targetWidth: 1920,
                        targetHeight: 1080,
                        frameRate: 60
                    )
                )
            ],
            cameras: [
                CameraCaptureSource(
                    id: "camera-a",
                    name: "Camera A",
                    deviceType: "external",
                    modelID: "camera-a",
                    width: 1920,
                    height: 1080,
                    isExternal: true,
                    formatSummary: ""
                )
            ],
            audioDevices: []
        )

        #expect(plans.count == 1)
        #expect(plans[0].request.videoInputs.count == 1)
        #expect(plans[0].request.videoInputs[0].targetWidth == 1920)
        #expect(plans[0].request.videoInputs[0].targetHeight == 1080)
        #expect(plans[0].request.videoInputs[0].frameRate == 60)
    }
}
