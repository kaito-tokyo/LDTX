// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXCapture
import Testing

@Suite
struct SharedCaptureSessionPlannerUnitTestSuite {
  @Test func deviceFailureOnlyTargetsSubscriptionsUsingThatDevice() {
    let cameraSubscription = UUID()
    let otherCameraSubscription = UUID()
    let routes = [
      cameraSubscription: Set([SharedCaptureSessionRouteInterest(deviceID: "camera-a")]),
      otherCameraSubscription: Set([SharedCaptureSessionRouteInterest(deviceID: "camera-b")]),
    ]

    #expect(
      SharedCaptureFailureRouter.subscriptionIDs(
        for: .deviceDisconnected(deviceID: "camera-a"),
        routesBySubscriptionID: routes
      ) == [cameraSubscription])
    #expect(
      SharedCaptureFailureRouter.subscriptionIDs(
        for: .sessionRuntimeError(code: -1),
        routesBySubscriptionID: routes
      ) == [cameraSubscription, otherCameraSubscription])
  }

  @Test func linkedVideoSubscriptionsShareOneSessionPlan() {
    let plans = SharedCaptureSessionPlanner.makePlans(
      subscriptions: [
        UUID(): SharedCaptureSessionSubscriptionDemand(
          video: SharedCaptureSessionVideoDemand(
            deviceID: "camera-a",
            targetWidth: 1280,
            targetHeight: 720,
            frameRate: 30
          )),
        UUID(): SharedCaptureSessionSubscriptionDemand(
          video: SharedCaptureSessionVideoDemand(
            deviceID: "camera-linked",
            targetWidth: 640,
            targetHeight: 480,
            frameRate: 30
          )),
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
          linkedDeviceIDs: ["camera-linked"]
        ),
        CameraCaptureSource(
          id: "camera-linked",
          name: "Linked Camera",
          deviceType: "external",
          modelID: "camera-linked",
          width: 640,
          height: 480,
          isExternal: true,
          formatSummary: "",
          linkedDeviceIDs: ["camera-a"]
        ),
      ]
    )

    #expect(plans.count == 1)
    #expect(plans[0].request.videoInputs.count == 2)
    #expect(plans[0].key.groupedDeviceIDs == ["camera-a", "camera-linked"])
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
          )),
        UUID(): SharedCaptureSessionSubscriptionDemand(
          video: SharedCaptureSessionVideoDemand(
            deviceID: "camera-a",
            targetWidth: 1920,
            targetHeight: 1080,
            frameRate: 60
          )),
      ],
      cameras: []
    )

    #expect(plans.count == 1)
    #expect(plans[0].request.videoInputs.count == 1)
    #expect(plans[0].request.videoInputs[0].targetWidth == 1920)
    #expect(plans[0].request.videoInputs[0].targetHeight == 1080)
    #expect(plans[0].request.videoInputs[0].frameRate == 60)
  }
}
