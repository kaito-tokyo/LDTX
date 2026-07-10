// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LDTXCapture

final class SharedCaptureSessionPlannerTests: XCTestCase {
    func testLinkedVideoAndAudioShareOneSessionPlan() {
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

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].request.videoInputs.map(\.deviceID), ["camera-a"])
        XCTAssertEqual(plans[0].request.audioInputs.map(\.deviceID), ["mic-a"])
        XCTAssertEqual(plans[0].key.groupedDeviceIDs, ["camera-a", "mic-a"])
    }

    func testUnlinkedDevicesStayInSeparateSessions() {
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

        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(
            plans.map {
                "\($0.request.videoInputs.map(\.deviceID).joined(separator: ","))|\($0.request.audioInputs.map(\.deviceID).joined(separator: ","))"
            }.sorted(),
            ["camera-a|", "|mic-b"]
        )
    }

    func testAggregatesVideoDemandToHighestRequestedConfiguration() {
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

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].request.videoInputs.count, 1)
        XCTAssertEqual(plans[0].request.videoInputs[0].targetWidth, 1920)
        XCTAssertEqual(plans[0].request.videoInputs[0].targetHeight, 1080)
        XCTAssertEqual(plans[0].request.videoInputs[0].frameRate, 60)
    }
}
