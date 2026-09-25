// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

@Suite
@MainActor
struct SwiftUIViewStateUnitTestSuite {
  @Test func itemNameDialogNormalizesCandidateAndValidatesAvailability() {
    let name = BindingState("  Camera  \n")
    let dialog = ItemNameDialog(
      name: binding(to: name), title: "Add Input", fieldTitle: "Name",
      isNameAvailable: { $0 != "Taken" }, submit: { _ in }, cancel: {})

    #expect(dialog.candidate == "Camera")
    #expect(dialog.canSubmit)
    name.value = " Taken \n"
    #expect(dialog.candidate == "Taken")
    #expect(!dialog.canSubmit)
    name.value = " \n  "
    #expect(dialog.candidate.isEmpty)
    #expect(!dialog.canSubmit)
    _ = dialog.body
  }

  @Test func programNameDialogRejectsEmptyUnchangedAndUnavailableNames() {
    let name = BindingState("  Camera  \n")
    let dialog = ProgramNameDialog(
      name: binding(to: name), title: "Rename Program", actionTitle: "Rename",
      currentName: "Current", isNameAvailable: { $0 != "Taken" }, submit: {}, cancel: {})

    #expect(dialog.trimmedName == "Camera")
    #expect(dialog.canSubmit)
    name.value = " Current "
    #expect(!dialog.canSubmit)
    name.value = " Taken "
    #expect(!dialog.canSubmit)
    name.value = " \n "
    #expect(!dialog.canSubmit)
    _ = dialog.body
  }

  @Test func addInputDeviceDialogSelectionUpdatesItsBoundState() {
    let kind = BindingState<ProgramInputDeviceKind>(.video)
    let physicalDeviceID = BindingState<String?>(nil)
    let nameLabel = BindingState("Camera")
    let cameras = [InputPhysicalDeviceOption(id: "camera-1", name: "Camera", isExternal: true)]
    let audioDevices = [
      InputPhysicalDeviceOption(id: "microphone-1", name: "Microphone", isExternal: false)
    ]
    let dialog = AddInputDeviceDialog(
      kind: binding(to: kind), physicalDeviceID: binding(to: physicalDeviceID),
      nameLabel: binding(to: nameLabel), isNameAvailable: true, cameras: cameras,
      audioDevices: audioDevices, submit: {}, cancel: {})

    #expect(dialog.selectedDeviceName.isEmpty)
    #expect(dialog.availableDevices == cameras)
    #expect(!dialog.isAddEnabled)

    dialog.selectDevice(audioDevices[0], isAudio: true)

    #expect(kind.value == .audio)
    #expect(physicalDeviceID.value == "microphone-1")
    #expect(dialog.selectedDeviceName == "Microphone")
    #expect(dialog.availableDevices == audioDevices)
    #expect(dialog.isAddEnabled)
    _ = dialog.body
  }

  @Test func inputDeviceSectionEnablesEditingInUnlockedEditMode() {
    let windowState = WorkspaceWindowState(
      mode: .edit, outputSessionState: .idle, isOperationLocked: false)
    let section = InputDevicesSidebarSection(
      inputDevices: .constant([]), selectedSidebarItem: .constant(nil),
      windowState: windowState, beginAddingDevice: {})

    #expect(section.isInputDeviceEditable)
    _ = section.body
  }

  @Test func inputDeviceSectionDisablesEditingWhenOperationIsLocked() {
    let windowState = WorkspaceWindowState(
      mode: .edit, outputSessionState: .idle, isOperationLocked: true)
    let section = InputDevicesSidebarSection(
      inputDevices: .constant([]), selectedSidebarItem: .constant(nil),
      windowState: windowState, beginAddingDevice: {})

    #expect(!section.isInputDeviceEditable)
    _ = section.body
  }

  @Test func inputDeviceSectionDisablesEditingInOutputMode() {
    let windowState = WorkspaceWindowState(
      mode: .output, outputSessionState: .running, isOperationLocked: false)
    let section = InputDevicesSidebarSection(
      inputDevices: .constant([]), selectedSidebarItem: .constant(nil),
      windowState: windowState, beginAddingDevice: {})

    #expect(!section.isInputDeviceEditable)
    _ = section.body
  }

  @Test(arguments: [
    ("Camera A", "Camera C", ["Camera B", "Camera C", "Camera A"]),
    ("Camera C", "Camera A", ["Camera C", "Camera A", "Camera B"]),
  ])
  func inputDeviceDropReordersAcrossDestination(
    draggedName: String, destinationName: String, expectedNames: [String]
  ) {
    let devices = [
      inputDevice(named: "Camera A"), inputDevice(named: "Camera B"),
      inputDevice(named: "Camera C"),
    ]
    let reordered = InputDeviceDropDelegate.reordered(
      devices, draggedName: draggedName, destinationName: destinationName)

    #expect(reordered?.map(\.name) == expectedNames)
  }

  @Test func inputDeviceDropLeavesItemsUnchangedWhenNamesDoNotResolveToMove() {
    let devices = [inputDevice(named: "Camera A"), inputDevice(named: "Camera B")]

    #expect(
      InputDeviceDropDelegate.reordered(
        devices, draggedName: "Camera A", destinationName: "Camera A") == nil)
    #expect(
      InputDeviceDropDelegate.reordered(
        devices, draggedName: "Missing", destinationName: "Camera B") == nil)
    #expect(
      InputDeviceDropDelegate.reordered(
        devices, draggedName: "Camera A", destinationName: "Missing") == nil)
    #expect(devices.map(\.name) == ["Camera A", "Camera B"])
  }

  private func inputDevice(named name: String) -> ProgramInputDeviceRecord {
    ProgramInputDeviceRecord(name: name, kind: .video)
  }

  private func binding<Value>(to state: BindingState<Value>) -> Binding<Value> {
    Binding(get: { state.value }, set: { state.value = $0 })
  }

  private final class BindingState<Value> {
    var value: Value

    init(_ value: Value) {
      self.value = value
    }
  }
}
