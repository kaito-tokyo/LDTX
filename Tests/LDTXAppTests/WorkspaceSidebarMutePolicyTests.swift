// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import Testing

@testable import LDTXAppUI

@MainActor
struct WorkspaceSidebarMutePolicyTests {
  @Test func muteControlAppearsForVideoAndAudioInputs() {
    #expect(WorkspaceSidebarPane.showsMuteControl(for: .video))
    #expect(WorkspaceSidebarPane.showsMuteControl(for: .audio))
    #expect(!WorkspaceSidebarPane.showsMuteControl(for: .unspecified))
  }

  @Test func videoMuteIsIndependentOfWorkspaceStructuralEditing() {
    #expect(WorkspaceSidebarPane.isMuteControlEnabled(for: .video))
  }

  @Test func audioMuteIsIndependentOfWorkspaceStructuralEditing() {
    #expect(WorkspaceSidebarPane.isMuteControlEnabled(for: .audio))
  }

  @Test func videoComponentNamesParticipateInGlobalResourceValidation() {
    let component = WorkspaceVideoComponentRecord(name: "Shared Name")

    #expect(!WorkspaceResourceNameValidator.isAvailable(
      "Shared Name",
      inputDevices: [],
      videoComponents: [component],
      visions: []
    ))
  }

  @Test func contentSelectionFollowsExistingWorkspaceResources() {
    let videoInput = WorkspaceInputDeviceRecord(name: "1-Camera", kind: .video)
    let component = WorkspaceVideoComponentRecord(name: "2-Camera Video", inputDeviceID: videoInput.id)

    #expect(WorkspaceContentSelection.resolve(
      selectedSidebarItem: .streamSettings,
      inputDevices: [videoInput],
      videoComponents: [component]
    ) == .program)
    #expect(WorkspaceContentSelection.resolve(
      selectedSidebarItem: .inputDevice(videoInput.id),
      inputDevices: [videoInput],
      videoComponents: [component]
    ) == .inputDevice(videoInput.id))
    #expect(WorkspaceContentSelection.resolve(
      selectedSidebarItem: .videoComponent(component.id),
      inputDevices: [videoInput],
      videoComponents: [component]
    ) == .videoComponent(component.id))
    #expect(WorkspaceContentSelection.resolve(
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
}

private extension ProgramComponent {
  var inputDeviceComponent: InputDeviceComponent? {
    guard case .inputCameraDevice(let component) = self else { return nil }
    return component
  }
}
