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
import LDTXWorkspaceAppletController
import LDTXYouTubeRTMPS
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceV4Sidebar: View {
  @Bindable var session: WorkspaceV4RuntimeSession
  let synchronizeVision: () -> Void
  let submitVision: (UInt64) -> Void
  let refreshOutputMix: () -> Void
  let outputIsActive: () -> Bool
  let synchronizeAudioMonitor: () -> Void
  @State private var errorMessage: String?

  var body: some View {
    List {
      Section("Programs") {
        ForEach(session.definition.programs, id: \.internalID) {
          program in
          HStack {
            Button(program.displayName) {
              session.selectedProgramInternalID = program.internalID
              synchronizeAudioMonitor()
              refreshOutputMix()
            }
            .buttonStyle(.plain)
            Spacer()
            Button(role: .destructive) {
              try? session.removeProgram(internalID: program.internalID)
              synchronizeAudioMonitor()
            } label: {
              Image(systemName: "minus")
            }
            .accessibilityLabel("Remove \(program.displayName)")
            .disabled(outputIsActive())
          }
        }
      }
      Section("Input Devices") {
        ForEach(session.definition.inputDevices.indices, id: \.self) {
          index in
          let input = session.definition.inputDevices[index]
          HStack {
            Text(inputLabel(input))
            Spacer()
            Button(role: .destructive) {
              removeInputDevice(input)
            } label: {
              Image(systemName: "minus")
            }
            .accessibilityLabel("Remove \(inputLabel(input))")
            .disabled(outputIsActive())
          }
        }
      }
      Section("Video Components") {
        ForEach(session.definition.videoComponents.indices, id: \.self) {
          index in
          let component = session.definition.videoComponents[index]
          HStack {
            Text(componentLabel(component))
            Spacer()
            Button(role: .destructive) {
              removeVideoComponent(component)
            } label: {
              Image(systemName: "minus")
            }
            .accessibilityLabel("Remove \(componentLabel(component))")
            .disabled(outputIsActive())
          }
        }
      }
      Section("Visions") {
        ForEach(session.definition.visions.indices, id: \.self) {
          index in
          let vision = session.definition.visions[index]
          VStack(alignment: .leading) {
            HStack {
              Text(visionLabel(vision))
              Spacer()
              Button(role: .destructive) {
                removeVision(vision)
              } label: {
                Image(systemName: "minus")
              }
              .accessibilityLabel("Remove \(visionLabel(vision))")
              .disabled(outputIsActive())
            }
            if case .ocrVision(let value)? = vision.definition,
              let result = session.visionResults[value.internalID]
            {
              Text(result).font(.caption).lineLimit(3)
            }
            if case .ocrVision(let value)? = vision.definition, value.triggers.isEmpty {
              Button("Analyze Current Frame") { submitVision(value.internalID) }
                .disabled(outputIsActive())
            }
            if case .ocrVision(let value)? = vision.definition,
              let failure = session.visionFailureMessages[value.internalID]
            {
              Text(failure).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .alert(
      "Cannot Remove Resource",
      isPresented: Binding(
        get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func inputLabel(_ input: Ldtx_Workspace_V4_InputDeviceWrapper) -> String {
    switch input.definition {
    case .videoDevice(let device): device.displayName
    case .audioDevice(let device): device.displayName
    case nil: "Invalid Input Device"
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

