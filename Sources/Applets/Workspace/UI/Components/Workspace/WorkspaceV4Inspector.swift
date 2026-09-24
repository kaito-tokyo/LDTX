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

struct WorkspaceV4Inspector: View {
  @Bindable var session: WorkspaceV4RuntimeSession
  @Bindable var recordingSession: WorkspaceV4RecordingSession
  @State private var streamKeyConfigurations: [YouTubeRTMPSStreamKeyConfiguration] = []
  @State private var isShowingStreamKeyManager = false
  var body: some View {
    Form {
      Section("Workspace") {
        Text(workspaceStateLabel)
          .foregroundStyle(.secondary)
      }
      Section("Canvas") {
        Stepper("Frame Rate: \(frameRate)", value: frameRateBinding, in: 1...240)
          .disabled(recordingSession.isRecording)
      }
      Section("Output") {
        TextField("Recording Folder", text: outputFolderPathBinding)
          .disabled(recordingSession.isRecording)
        Group {
          Toggle("Record Landscape", isOn: outputBinding(\.recordsLandscape))
          Toggle("Record Portrait", isOn: outputBinding(\.recordsPortrait))
          Toggle("Stream to YouTube", isOn: outputBinding(\.streamsToYoutube))
          Picker("YouTube Ingest", selection: ingestModeBinding) {
            ForEach(ingestModes, id: \.rawValue) { mode in
              Text(ingestModeLabel(mode)).tag(mode)
            }
          }
          if !isAvailableIngestMode(
            session.definition.outputConfiguration
              .resolvedYouTubeIngestMode)
          {
            Text("This YouTube ingest mode is not available yet.")
              .foregroundStyle(.secondary)
          }
          if usesLandscapeRTMPS {
            streamKeyPicker("Landscape Stream Key", selection: landscapeStreamKeyBinding)
          }
          if usesPortraitRTMPS {
            streamKeyPicker("Portrait Stream Key", selection: portraitStreamKeyBinding)
          }
          Button("Manage Stream Keys") { isShowingStreamKeyManager = true }
            .popover(isPresented: $isShowingStreamKeyManager) {
              WorkspaceV4StreamKeyManager(
                configurations: streamKeyConfigurations,
                load: { try session.loadYouTubeStreamKeyConfigurations() },
                save: { configurations in
                  try session.saveYouTubeStreamKeyConfigurations(configurations)
                  streamKeyConfigurations = configurations
                }
              )
            }
        }
        .disabled(recordingSession.isRecording)
      }
    }
    .padding(16)
    .accessibilityIdentifier("workspaceInspector")
    .onAppear {
      streamKeyConfigurations = (try? session.loadYouTubeStreamKeyConfigurations()) ?? []
    }
  }

  private var frameRate: Int {
    let value = session.definition.canvasConfiguration.frameRate
    return value == 0 ? 60 : Int(value)
  }

  private var workspaceStateLabel: String {
    guard session.url != nil else { return "Unsaved Workspace" }
    return session.isDirty ? "Unsaved changes" : "Saved"
  }

  private var frameRateBinding: Binding<Int> {
    Binding(
      get: { frameRate },
      set: { value in
        try? session.editDefinition { $0.canvasConfiguration.frameRate = UInt32(value) }
        session.updateRuntimes()
        let availableCameraIDs = Set(session.availableCaptureDevices().cameras.map(\.id))
        session.synchronizeCaptureInputs(availableCameraIDs: availableCameraIDs) { _ in }
      }
    )
  }

  private func outputBinding(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_OutputConfiguration, Bool>
  ) -> Binding<Bool> {
    Binding(
      get: { session.definition.outputConfiguration[keyPath: keyPath] },
      set: { value in
        try? session.editDefinition { definition in
          definition.outputConfiguration[keyPath: keyPath] = value
        }
      }
    )
  }

  private var ingestModeBinding: Binding<Ldtx_Workspace_V4_YouTubeIngestMode> {
    Binding(
      get: {
        session.definition.outputConfiguration.resolvedYouTubeIngestMode
      },
      set: { value in
        try? session.editDefinition { $0.outputConfiguration.youtubeIngestMode = value }
      }
    )
  }

  private var outputFolderPathBinding: Binding<String> {
    Binding(
      get: {
        let output = session.definition.outputConfiguration
        return output.hasOutputFolderPath ? output.outputFolderPath : ""
      },
      set: { path in
        try? session.editDefinition { definition in
          if path.isEmpty {
            definition.outputConfiguration.clearOutputFolderPath()
          } else {
            definition.outputConfiguration.outputFolderPath = path
          }
        }
      }
    )
  }

  private var ingestModes: [Ldtx_Workspace_V4_YouTubeIngestMode] {
    [
      .landscapeRtmps, .portraitRtmps, .dualRtmps,
    ]
  }

  private func isAvailableIngestMode(_ mode: Ldtx_Workspace_V4_YouTubeIngestMode) -> Bool {
    switch mode {
    case .landscapeRtmps, .portraitRtmps, .dualRtmps: true
    default: false
    }
  }

  private var usesLandscapeRTMPS: Bool {
    switch session.definition.outputConfiguration
      .resolvedYouTubeIngestMode
    {
    case .landscapeRtmps, .dualRtmps: true
    default: false
    }
  }

  private var usesPortraitRTMPS: Bool {
    switch session.definition.outputConfiguration
      .resolvedYouTubeIngestMode
    {
    case .portraitRtmps, .dualRtmps: true
    default: false
    }
  }

  private var landscapeStreamKeyBinding: Binding<String> {
    Binding(
      get: { session.landscapeYouTubeLiveStreamID ?? "" },
      set: { session.setLandscapeYouTubeLiveStreamID($0.isEmpty ? nil : $0) })
  }

  private var portraitStreamKeyBinding: Binding<String> {
    Binding(
      get: { session.portraitYouTubeLiveStreamID ?? "" },
      set: { session.setPortraitYouTubeLiveStreamID($0.isEmpty ? nil : $0) })
  }

  private func streamKeyPicker(_ title: String, selection: Binding<String>) -> some View {
    Picker(title, selection: selection) {
      Text("Select Stream Key").tag("")
      ForEach(streamKeyConfigurations) { configuration in
        Text(configuration.name).tag(configuration.id)
      }
    }
  }

  private func ingestModeLabel(_ mode: Ldtx_Workspace_V4_YouTubeIngestMode) -> String {
    switch mode {
    case .landscapeRtmps: "Landscape RTMPS"
    case .portraitRtmps: "Portrait RTMPS"
    case .dualRtmps: "Dual RTMPS"
    case .landscapeHls: "Landscape HLS"
    case .portraitHls: "Portrait HLS"
    case .landscapeDash: "Landscape DASH"
    case .portraitDash: "Portrait DASH"
    case .unspecified, .UNRECOGNIZED: "Unspecified"
    }
  }
}
