// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletStore
import LDTXWorkspaceAppletService
import LDTXYouTubeRTMPS
import SwiftUI
import UniformTypeIdentifiers

private enum WorkspaceSidebarAddTarget {
  case inputDevices
  case videoComponents
  case visions

  var title: String {
    switch self {
    case .inputDevices: "Add Input Device"
    case .videoComponents: "Add Video Component"
    case .visions: "Add Vision"
    }
  }
}

struct WorkspaceV4Sidebar: View {
  @Bindable var store: WorkspaceV4Store
  @Bindable var session: WorkspaceV4SessionService
  let synchronizeVision: () -> Void
  let submitVision: (UInt64) -> Void
  let refreshOutputMix: () -> Void
  let outputIsActive: () -> Bool
  let synchronizeAudioMonitor: () -> Void
  @State private var selectedSidebarItem: WorkspaceSidebarItem? = .videoLayers
  @State private var isShowingAddActions = false
  @State private var addTarget: WorkspaceSidebarAddTarget = .inputDevices
  @State private var errorMessage: String?

  var body: some View {
    List(selection: $selectedSidebarItem) {
      Label("Video Layers", systemImage: "square.stack.3d.up")
        .foregroundStyle(.primary)
        .tag(WorkspaceSidebarItem.videoLayers)
      Label("Video Layers", systemImage: "square.stack.3d.up")
        .foregroundStyle(.primary)
        .tag(WorkspaceSidebarItem.videoLayers)
      Label("Canvas", systemImage: "rectangle.on.rectangle")
    }
    .listStyle(.sidebar)
    //    List(selection: $selectedSidebarItem) {
    //      VStack {
    //        Label("Video Layers", systemImage: "square.stack.3d.up")
    //          .foregroundStyle(.primary)
    //          .tag(WorkspaceSidebarItem.videoLayers)
    //        Label("Canvas", systemImage: "rectangle.on.rectangle")
    //          .foregroundStyle(.primary)
    //          .tag(WorkspaceSidebarItem.canvas)
    //        Label("Output", systemImage: "dot.radiowaves.left.and.right")
    //          .foregroundStyle(.primary)
    //
    //        VStack(spacing: 0) {
    //          List(selection: $selectedSidebarItem) {
    //            Label("Video Layers", systemImage: "square.stack.3d.up")
    //              .foregroundStyle(.primary)
    //              .tag(WorkspaceSidebarItem.videoLayers)
    //            Label("Canvas", systemImage: "rectangle.on.rectangle")
    //              .foregroundStyle(.primary)
    //              .tag(WorkspaceSidebarItem.canvas)
    //            Label("Output", systemImage: "dot.radiowaves.left.and.right")
    //              .foregroundStyle(.primary)
    //              .tag(WorkspaceSidebarItem.output)
    //
    //            Section {
    //              if store.definition.inputDevices.isEmpty {
    //                Text("No input devices").foregroundStyle(.secondary)
    //              }
    //              ForEach(store.definition.inputDevices.indices, id: \.self) { index in
    //                let input = store.definition.inputDevices[index]
    //                HStack {
    //                  Button {
    //                    selectedSidebarItem = .inputDevice(inputLabel(input))
    //                  } label: {
    //                    Label(inputLabel(input), systemImage: inputSystemImage(input))
    //                      .lineLimit(1)
    //                      .frame(maxWidth: .infinity, alignment: .leading)
    //                      .contentShape(Rectangle())
    //                  }
    //                  .buttonStyle(.plain)
    //                  Button(role: .destructive) {
    //                    removeInputDevice(input)
    //                  } label: {
    //                    Image(systemName: "minus")
    //                  }
    //                  .buttonStyle(.borderless)
    //                  .accessibilityLabel("Remove \(inputLabel(input))")
    //                  .disabled(outputIsActive())
    //                }
    //                .tag(WorkspaceSidebarItem.inputDevice(inputLabel(input)))
    //              }
    //            } header: {
    //              WorkspaceSidebarSectionHeader(
    //                title: "Input Devices",
    //                accessibilityIdentifier: "addWorkspaceInputDeviceButton",
    //                isAddEnabled: !outputIsActive(),
    //                add: { beginAdding(to: .inputDevices) }
    //              )
    //            }
    //
    //            Section {
    //              if store.definition.videoComponents.isEmpty {
    //                Text("No video components").foregroundStyle(.secondary)
    //              }
    //              ForEach(store.definition.videoComponents.indices, id: \.self) { index in
    //                let component = store.definition.videoComponents[index]
    //                HStack {
    //                  Button {
    //                    selectedSidebarItem = .videoComponent(componentLabel(component))
    //                  } label: {
    //                    Label(componentLabel(component), systemImage: componentSystemImage(component))
    //                      .lineLimit(1)
    //                      .frame(maxWidth: .infinity, alignment: .leading)
    //                      .contentShape(Rectangle())
    //                  }
    //                  .buttonStyle(.plain)
    //                  Button(role: .destructive) {
    //                    removeVideoComponent(component)
    //                  } label: {
    //                    Image(systemName: "minus")
    //                  }
    //                  .buttonStyle(.borderless)
    //                  .accessibilityLabel("Remove \(componentLabel(component))")
    //                  .disabled(outputIsActive())
    //                }
    //                .tag(WorkspaceSidebarItem.videoComponent(componentLabel(component)))
    //              }
    //            } header: {
    //              WorkspaceSidebarSectionHeader(
    //                title: "Video Components",
    //                accessibilityIdentifier: "addWorkspaceVideoComponentButton",
    //                isAddEnabled: !outputIsActive(),
    //                add: { beginAdding(to: .videoComponents) }
    //              )
    //            }
    //
    //            Section {
    //              if store.definition.visions.isEmpty {
    //                Text("No visions").foregroundStyle(.secondary)
    //              }
    //              ForEach(store.definition.visions.indices, id: \.self) { index in
    //                let vision = store.definition.visions[index]
    //                VStack(alignment: .leading) {
    //                  HStack {
    //                    Button {
    //                      selectedSidebarItem = .vision(visionLabel(vision))
    //                    } label: {
    //                      Label(visionLabel(vision), systemImage: "eye")
    //                        .lineLimit(1)
    //                        .frame(maxWidth: .infinity, alignment: .leading)
    //                        .contentShape(Rectangle())
    //                    }
    //                    .buttonStyle(.plain)
    //                    Button(role: .destructive) {
    //                      removeVision(vision)
    //                    } label: {
    //                      Image(systemName: "minus")
    //                    }
    //                    .buttonStyle(.borderless)
    //                    .accessibilityLabel("Remove \(visionLabel(vision))")
    //                    .disabled(outputIsActive())
    //                  }
    //                  .tag(WorkspaceSidebarItem.vision(visionLabel(vision)))
    //                  if case .ocrVision(let value)? = vision.definition,
    //                    let result = store.visionResults[value.internalID]
    //                  {
    //                    Text(result).font(.caption).lineLimit(3)
    //                  }
    //                  if case .ocrVision(let value)? = vision.definition, value.triggers.isEmpty {
    //                    Button("Analyze Current Frame") { submitVision(value.internalID) }
    //                      .disabled(outputIsActive())
    //                  }
    //                  if case .ocrVision(let value)? = vision.definition,
    //                    let failure = store.visionFailureMessages[value.internalID]
    //                  {
    //                    Text(failure).font(.caption).foregroundStyle(.red).lineLimit(3)
    //                  }
    //                }
    //              }
    //            } header: {
    //              WorkspaceSidebarSectionHeader(
    //                title: "Visions",
    //                accessibilityIdentifier: "addWorkspaceVisionButton",
    //                isAddEnabled: !outputIsActive(),
    //                add: { beginAdding(to: .visions) }
    //              )
    //            }
    //          }
    //
    //        }
    //      }
    //    }
    //    .listStyle(.sidebar)
    //    VStack(spacing: 0) {
    //      List(selection: $selectedSidebarItem) {
    //        Label("Video Layers", systemImage: "square.stack.3d.up")
    //          .foregroundStyle(.primary)
    //          .tag(WorkspaceSidebarItem.videoLayers)
    //        Label("Canvas", systemImage: "rectangle.on.rectangle")
    //          .foregroundStyle(.primary)
    //          .tag(WorkspaceSidebarItem.canvas)
    //        Label("Output", systemImage: "dot.radiowaves.left.and.right")
    //          .foregroundStyle(.primary)
    //          .tag(WorkspaceSidebarItem.output)
    //
    //        Section {
    //          if store.definition.inputDevices.isEmpty {
    //            Text("No input devices").foregroundStyle(.secondary)
    //          }
    //          ForEach(store.definition.inputDevices.indices, id: \.self) { index in
    //            let input = store.definition.inputDevices[index]
    //            HStack {
    //              Button {
    //                selectedSidebarItem = .inputDevice(inputLabel(input))
    //              } label: {
    //                Label(inputLabel(input), systemImage: inputSystemImage(input))
    //                  .lineLimit(1)
    //                  .frame(maxWidth: .infinity, alignment: .leading)
    //                  .contentShape(Rectangle())
    //              }
    //              .buttonStyle(.plain)
    //              Button(role: .destructive) {
    //                removeInputDevice(input)
    //              } label: {
    //                Image(systemName: "minus")
    //              }
    //              .buttonStyle(.borderless)
    //              .accessibilityLabel("Remove \(inputLabel(input))")
    //              .disabled(outputIsActive())
    //            }
    //            .tag(WorkspaceSidebarItem.inputDevice(inputLabel(input)))
    //          }
    //        } header: {
    //          WorkspaceSidebarSectionHeader(
    //            title: "Input Devices",
    //            accessibilityIdentifier: "addWorkspaceInputDeviceButton",
    //            isAddEnabled: !outputIsActive(),
    //            add: { beginAdding(to: .inputDevices) }
    //          )
    //        }
    //
    //        Section {
    //          if store.definition.videoComponents.isEmpty {
    //            Text("No video components").foregroundStyle(.secondary)
    //          }
    //          ForEach(store.definition.videoComponents.indices, id: \.self) { index in
    //            let component = store.definition.videoComponents[index]
    //            HStack {
    //              Button {
    //                selectedSidebarItem = .videoComponent(componentLabel(component))
    //              } label: {
    //                Label(componentLabel(component), systemImage: componentSystemImage(component))
    //                  .lineLimit(1)
    //                  .frame(maxWidth: .infinity, alignment: .leading)
    //                  .contentShape(Rectangle())
    //              }
    //              .buttonStyle(.plain)
    //              Button(role: .destructive) {
    //                removeVideoComponent(component)
    //              } label: {
    //                Image(systemName: "minus")
    //              }
    //              .buttonStyle(.borderless)
    //              .accessibilityLabel("Remove \(componentLabel(component))")
    //              .disabled(outputIsActive())
    //            }
    //            .tag(WorkspaceSidebarItem.videoComponent(componentLabel(component)))
    //          }
    //        } header: {
    //          WorkspaceSidebarSectionHeader(
    //            title: "Video Components",
    //            accessibilityIdentifier: "addWorkspaceVideoComponentButton",
    //            isAddEnabled: !outputIsActive(),
    //            add: { beginAdding(to: .videoComponents) }
    //          )
    //        }
    //
    //        Section {
    //          if store.definition.visions.isEmpty {
    //            Text("No visions").foregroundStyle(.secondary)
    //          }
    //          ForEach(store.definition.visions.indices, id: \.self) { index in
    //            let vision = store.definition.visions[index]
    //            VStack(alignment: .leading) {
    //              HStack {
    //                Button {
    //                  selectedSidebarItem = .vision(visionLabel(vision))
    //                } label: {
    //                  Label(visionLabel(vision), systemImage: "eye")
    //                    .lineLimit(1)
    //                    .frame(maxWidth: .infinity, alignment: .leading)
    //                    .contentShape(Rectangle())
    //                }
    //                .buttonStyle(.plain)
    //                Button(role: .destructive) {
    //                  removeVision(vision)
    //                } label: {
    //                  Image(systemName: "minus")
    //                }
    //                .buttonStyle(.borderless)
    //                .accessibilityLabel("Remove \(visionLabel(vision))")
    //                .disabled(outputIsActive())
    //              }
    //              .tag(WorkspaceSidebarItem.vision(visionLabel(vision)))
    //              if case .ocrVision(let value)? = vision.definition,
    //                let result = store.visionResults[value.internalID]
    //              {
    //                Text(result).font(.caption).lineLimit(3)
    //              }
    //              if case .ocrVision(let value)? = vision.definition, value.triggers.isEmpty {
    //                Button("Analyze Current Frame") { submitVision(value.internalID) }
    //                  .disabled(outputIsActive())
    //              }
    //              if case .ocrVision(let value)? = vision.definition,
    //                let failure = store.visionFailureMessages[value.internalID]
    //              {
    //                Text(failure).font(.caption).foregroundStyle(.red).lineLimit(3)
    //              }
    //            }
    //          }
    //        } header: {
    //          WorkspaceSidebarSectionHeader(
    //            title: "Visions",
    //            accessibilityIdentifier: "addWorkspaceVisionButton",
    //            isAddEnabled: !outputIsActive(),
    //            add: { beginAdding(to: .visions) }
    //          )
    //        }
    //      }
    //      .listStyle(.sidebar)
    //
    //      Divider()
    //      Button {
    //        selectedSidebarItem = .programs
    //        if let program = store.definition.programs.first {
    //          store.selectedProgramInternalID = program.internalID
    //          synchronizeAudioMonitor()
    //          refreshOutputMix()
    //        }
    //      } label: {
    //        HStack {
    //          Label("Programs", systemImage: "list.bullet.rectangle")
    //          Spacer(minLength: 0)
    //        }
    //        .padding(.horizontal, 12)
    //        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    //        .contentShape(Rectangle())
    //      }
    //      .buttonStyle(.plain)
    //      .background(selectedSidebarItem == .programs ? Color.accentColor.opacity(0.18) : .clear)
    //      .disabled(outputIsActive())
    //      .accessibilityIdentifier("manageProgramsButton")
    //    }
    //    .confirmationDialog(
    //      addTarget.title,
    //      isPresented: $isShowingAddActions,
    //      titleVisibility: .visible
    //    ) {
    //      addActions
    //      Button("Cancel", role: .cancel) {}
    //    }
    //    .alert(
    //      "Cannot Update Workspace",
    //      isPresented: Binding(
    //        get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
    //      )
    //    ) {
    //      Button("OK", role: .cancel) { errorMessage = nil }
    //    } message: {
    //      Text(errorMessage ?? "")
    //    }
  }

  @ViewBuilder
  private var addActions: some View {
    switch addTarget {
    case .inputDevices:
      Button("Video Input") { addInputDevice(isVideo: true) }
      Button("Audio Input") { addInputDevice(isVideo: false) }
    case .videoComponents:
      Button("VFX Source") { addVFXSource() }
        .disabled(firstVideoInputInternalID == nil)
      Button("Solid Color") {
        addVideoComponent {
          try session.addSolidColorFill(displayName: uniqueDisplayName("Solid Color"))
        }
      }
      Button("Linear Gradient") {
        addVideoComponent {
          try session.addLinearGradientFill(displayName: uniqueDisplayName("Linear Gradient"))
        }
      }
      Button("Radial Gradient") {
        addVideoComponent {
          try session.addRadialGradientFill(displayName: uniqueDisplayName("Radial Gradient"))
        }
      }
      Button("Conic Gradient") {
        addVideoComponent {
          try session.addConicGradientFill(displayName: uniqueDisplayName("Conic Gradient"))
        }
      }
      Button("Clock") {
        addVideoComponent { try session.addClock(displayName: uniqueDisplayName("Clock")) }
      }
      Button("Test Pattern") {
        addVideoComponent {
          try session.addTestPattern(displayName: uniqueDisplayName("Test Pattern"))
        }
      }
    case .visions:
      Button("OCR Vision") { addOcrVision() }
        .disabled(firstVideoInputInternalID == nil)
    }
  }

  private func beginAdding(to target: WorkspaceSidebarAddTarget) {
    addTarget = target
    isShowingAddActions = true
  }

  private func addInputDevice(isVideo: Bool) {
    do {
      let name = uniqueDisplayName(isVideo ? "Video Input" : "Audio Input")
      if isVideo {
        try session.addVideoInputDevice(displayName: name)
      } else {
        try session.addAudioInputDevice(displayName: name)
      }
      session.updateRuntimes()
      selectedSidebarItem = .inputDevice(name)
      synchronizeAudioMonitor()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func addVideoComponent(_ create: () throws -> UInt64) {
    do {
      let internalID = try create()
      session.updateRuntimes()
      if let component = store.definition.videoComponents.first(where: {
        componentInternalID($0) == internalID
      }) {
        selectedSidebarItem = .videoComponent(componentLabel(component))
      }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func addVFXSource() {
    guard let inputDeviceInternalID = firstVideoInputInternalID else { return }
    addVideoComponent {
      try session.addVFXSource(
        displayName: uniqueDisplayName("VFX Source"),
        inputDeviceInternalID: inputDeviceInternalID
      )
    }
  }

  private func addOcrVision() {
    guard let inputDeviceInternalID = firstVideoInputInternalID else { return }
    do {
      let name = uniqueDisplayName("OCR Vision")
      try session.addOcrVision(
        displayName: name,
        inputDeviceInternalID: inputDeviceInternalID
      )
      selectedSidebarItem = .vision(name)
      synchronizeVision()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private var firstVideoInputInternalID: UInt64? {
    for input in store.definition.inputDevices {
      if case .videoDevice(let device) = input.definition {
        return device.internalID
      }
    }
    return nil
  }

  private func uniqueDisplayName(_ base: String) -> String {
    let names = existingResourceNames
    guard names.contains(base) else { return base }
    var suffix = 2
    while names.contains("\(base) \(suffix)") { suffix += 1 }
    return "\(base) \(suffix)"
  }

  private var existingResourceNames: Set<String> {
    var names = Set<String>()
    for input in store.definition.inputDevices {
      switch input.definition {
      case .videoDevice(let value): names.insert(value.displayName)
      case .audioDevice(let value): names.insert(value.displayName)
      case nil: break
      }
    }
    for component in store.definition.videoComponents {
      switch component.definition {
      case .vfxSource(let value): names.insert(value.displayName)
      case .solidColorFill(let value): names.insert(value.displayName)
      case .linearGradientFill(let value): names.insert(value.displayName)
      case .radialGradientFill(let value): names.insert(value.displayName)
      case .conicGradientFill(let value): names.insert(value.displayName)
      case .clock(let value): names.insert(value.displayName)
      case .testPattern(let value): names.insert(value.displayName)
      case nil: break
      }
    }
    for vision in store.definition.visions {
      if case .ocrVision(let value) = vision.definition {
        names.insert(value.displayName)
      }
    }
    return names
  }

  private func inputLabel(_ input: Ldtx_Workspace_V4_InputDeviceWrapper) -> String {
    switch input.definition {
    case .videoDevice(let device): device.displayName
    case .audioDevice(let device): device.displayName
    case nil: "Invalid Input Device"
    }
  }

  private func inputSystemImage(_ input: Ldtx_Workspace_V4_InputDeviceWrapper) -> String {
    switch input.definition {
    case .videoDevice: "video"
    case .audioDevice: "waveform"
    case nil: "questionmark.square.dashed"
    }
  }

  private func componentLabel(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> String {
    switch component.definition {
    case .vfxSource(let value): value.displayName
    case .solidColorFill(let value): value.displayName
    case .linearGradientFill(let value): value.displayName
    case .radialGradientFill(let value): value.displayName
    case .conicGradientFill(let value): value.displayName
    case .clock(let value): value.displayName
    case .testPattern(let value): value.displayName
    case nil: "Invalid Video Component"
    }
  }

  private func componentSystemImage(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> String
  {
    switch component.definition {
    case .vfxSource: "play.rectangle"
    case .solidColorFill, .linearGradientFill, .radialGradientFill, .conicGradientFill:
      "paintpalette"
    case .clock: "clock"
    case .testPattern: "testtube.2"
    case nil: "questionmark.square.dashed"
    }
  }

  private func visionLabel(_ vision: Ldtx_Workspace_V4_VisionWrapper) -> String {
    switch vision.definition {
    case .ocrVision(let value): value.displayName
    case nil: "Invalid Vision"
    }
  }

  private func removeInputDevice(_ input: Ldtx_Workspace_V4_InputDeviceWrapper) {
    let internalID: UInt64
    switch input.definition {
    case .videoDevice(let value): internalID = value.internalID
    case .audioDevice(let value): internalID = value.internalID
    case nil: return
    }
    do {
      try session.removeInputDevice(internalID: internalID)
      session.updateRuntimes()
      synchronizeVision()
      let availableCameraIDs = Set(session.availableCaptureDevices().cameras.map(\.id))
      session.synchronizeCaptureInputs(availableCameraIDs: availableCameraIDs) { _ in }
      synchronizeAudioMonitor()
    } catch { errorMessage = error.localizedDescription }
  }

  private func removeVideoComponent(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) {
    guard let internalID = componentInternalID(component) else { return }
    do {
      try session.removeVideoComponent(internalID: internalID)
      session.updateRuntimes()
    } catch { errorMessage = error.localizedDescription }
  }

  private func removeVision(_ vision: Ldtx_Workspace_V4_VisionWrapper) {
    guard case .ocrVision(let value)? = vision.definition else { return }
    do {
      try session.removeVision(internalID: value.internalID)
      synchronizeVision()
    } catch { errorMessage = error.localizedDescription }
  }

  private func componentInternalID(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> UInt64?
  {
    switch component.definition {
    case .vfxSource(let value): value.internalID
    case .solidColorFill(let value): value.internalID
    case .linearGradientFill(let value): value.internalID
    case .radialGradientFill(let value): value.internalID
    case .conicGradientFill(let value): value.internalID
    case .clock(let value): value.internalID
    case .testPattern(let value): value.internalID
    case nil: nil
    }
  }
}

#Preview("Workspace Sidebar") {
  let session = makeWorkspaceV4SidebarPreviewSession()

  WorkspaceV4Sidebar(
    store: session.store,
    session: session,
    synchronizeVision: {},
    submitVision: { _ in },
    refreshOutputMix: {},
    outputIsActive: { false },
    synchronizeAudioMonitor: {}
  )
  .frame(width: 260, height: 640)
}

@MainActor
private func makeWorkspaceV4SidebarPreviewSession() -> WorkspaceV4SessionService {
  let session = WorkspaceV4SessionService(
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
  try? session.create(displayName: "Workspace Sidebar Preview")
  return session
}
