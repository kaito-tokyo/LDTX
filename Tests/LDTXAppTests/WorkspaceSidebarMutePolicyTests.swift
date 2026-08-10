// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import Testing

@testable import LDTXAppUI

@MainActor
struct WorkspaceSidebarMutePolicyTests {
  @Test func directVideoInputLayerSupportsXYScale() {
    let videoInput = WorkspaceInputDeviceRecord(name: "Camera", kind: .video)
    let audioInput = WorkspaceInputDeviceRecord(name: "Microphone", kind: .audio)

    #expect(
      VideoLayerDestinationPolicy.supportsDestination(
        layerName: videoInput.name,
        inputDevices: [videoInput, audioInput],
        videoComponents: []
      ))
    #expect(
      !VideoLayerDestinationPolicy.supportsDestination(
        layerName: audioInput.name,
        inputDevices: [videoInput, audioInput],
        videoComponents: []
      ))
  }

  @Test func videoComponentNamesParticipateInGlobalResourceValidation() {
    let component = WorkspaceVideoComponentRecord(name: "Shared Name")

    #expect(
      !WorkspaceResourceNameValidator.isAvailable(
        "Shared Name",
        inputDevices: [],
        videoComponents: [component],
        visions: []
      ))
  }

  @Test func contentSelectionFollowsExistingWorkspaceResources() {
    let videoInput = WorkspaceInputDeviceRecord(name: "1-Camera", kind: .video)
    let component = WorkspaceVideoComponentRecord(
      name: "2-Camera Video", inputDeviceID: videoInput.id)

    #expect(
      WorkspaceContentSelection.resolve(
        selectedSidebarItem: .output,
        inputDevices: [videoInput],
        videoComponents: [component]
      ) == .program)
    #expect(
      WorkspaceContentSelection.resolve(
        selectedSidebarItem: .videoLayers,
        inputDevices: [videoInput],
        videoComponents: [component]
      ) == .program)
    #expect(
      WorkspaceContentSelection.resolve(
        selectedSidebarItem: .inputDevice(videoInput.id),
        inputDevices: [videoInput],
        videoComponents: [component]
      ) == .inputDevice(videoInput.id))
    #expect(
      WorkspaceContentSelection.resolve(
        selectedSidebarItem: .videoComponent(component.id),
        inputDevices: [videoInput],
        videoComponents: [component]
      ) == .videoComponent(component.id))
    #expect(
      WorkspaceContentSelection.resolve(
        selectedSidebarItem: .inputDevice("deleted"),
        inputDevices: [videoInput],
        videoComponents: [component]
      ) == .empty)
  }

  @Test func inputDevicePreviewUsesAnUnprocessedIdentityStep() throws {
    let input = WorkspaceInputDeviceRecord(name: "1-Camera", kind: .video)
    let composite = WorkspaceResourcePreviewFactory.inputDeviceComposite(input)
    let step = try #require(composite.steps.first)
    let payload = try #require(step.component.inputDeviceComponent)

    #expect(composite.steps.count == 1)
    #expect(payload.inputDeviceID == input.id)
    #expect(payload.sourceCropTop == 0)
    #expect(payload.sourceCropRight == 0)
    #expect(payload.sourceCropBottom == 0)
    #expect(payload.sourceCropLeft == 0)
    #expect(payload.destinationX == 0)
    #expect(payload.destinationY == 0)
    #expect(payload.destinationScale == 1)
    #expect(!payload.removesBackground)
  }

  @Test func videoComponentPreviewAppliesProcessingButNotDestination() throws {
    let resource = WorkspaceVideoComponentRecord(
      name: "2-Camera Video",
      inputDeviceID: "1-Camera",
      sourceCropTop: 10,
      sourceCropRight: 20,
      sourceCropBottom: 30,
      sourceCropLeft: 40,
      removesBackground: true
    )
    let composite = WorkspaceResourcePreviewFactory.videoComponentComposite(
      resource,
      supportsBackgroundRemoval: true
    )
    let payload = try #require(composite.steps.first?.component.inputDeviceComponent)

    #expect(composite.steps.count == 1)
    #expect(payload.inputDeviceID == "1-Camera")
    #expect(payload.sourceCropTop == 10)
    #expect(payload.sourceCropRight == 20)
    #expect(payload.sourceCropBottom == 30)
    #expect(payload.sourceCropLeft == 40)
    #expect(payload.destinationX == 0)
    #expect(payload.destinationY == 0)
    #expect(payload.destinationScale == 1)
    #expect(payload.removesBackground)
  }

  @Test func videoComponentPreviewOmitsUnavailableBackgroundRemoval() throws {
    let resource = WorkspaceVideoComponentRecord(
      name: "2-Camera Video",
      inputDeviceID: "1-Camera",
      sourceCropTop: 10,
      removesBackground: true
    )
    let composite = WorkspaceResourcePreviewFactory.videoComponentComposite(
      resource,
      supportsBackgroundRemoval: false
    )
    let payload = try #require(composite.steps.first?.component.inputDeviceComponent)

    #expect(payload.sourceCropTop == 10)
    #expect(!payload.removesBackground)
  }

  @Test func clockVideoComponentPreviewFitsTheWholeCanvas() throws {
    let resource = WorkspaceVideoComponentRecord(
      name: "1-Clock",
      component: .clock(
        ClockComponent(
          destinationX: 0.25,
          destinationY: 0.3,
          destinationWidth: 0.4,
          destinationHeight: 0.2
        ))
    )
    let composite = WorkspaceResourcePreviewFactory.videoComponentComposite(
      resource,
      supportsBackgroundRemoval: false
    )
    guard case .clock(let payload) = try #require(composite.steps.first).component else {
      Issue.record("Expected Clock")
      return
    }

    #expect(payload.destinationX == 0)
    #expect(payload.destinationY == 0)
    #expect(payload.destinationWidth == 1)
    #expect(payload.destinationHeight == 1)
  }
}

extension ProgramComponent {
  fileprivate var inputDeviceComponent: InputDeviceComponent? {
    guard case .inputCameraDevice(let component) = self else { return nil }
    return component
  }
}
