// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct WorkspaceCanvasInspector: View {
  let store: any WorkspaceBundleStoreProtocol
  let session: any WorkspaceSessionProtocol
  let recordingSession: any WorkspaceRecordingSessionProtocol
  let uiState: WorkspaceUIState

  var body: some View {
    Section("Canvas") {
      Stepper("Frame Rate: \(frameRate)", value: frameRateBinding, in: 1...240)
        .disabled(recordingSession.isRecording)
      LabeledContent("Landscape Profile", value: canvas.landscapeProfileID)
      LabeledContent("Portrait Profile", value: canvas.portraitProfileID)
      LabeledContent("Landscape Bit Rate") {
        TextField("Bits per second", value: landscapeBitRateBinding, format: .number)
          .multilineTextAlignment(.trailing)
          .frame(width: 110)
      }
      LabeledContent("Portrait Bit Rate") {
        TextField("Bits per second", value: portraitBitRateBinding, format: .number)
          .multilineTextAlignment(.trailing)
          .frame(width: 110)
      }
      Picker("PTS Master Camera", selection: ptsMasterBinding) {
        Text("Automatic").tag(nil as UInt64?)
        ForEach(videoDevices, id: \.internalID) { device in
          Text(device.displayName).tag(Optional(device.internalID))
        }
      }
      .disabled(recordingSession.isRecording)
    }
    .disabled(recordingSession.isRecording)
  }

  private var canvas: Ldtx_Workspace_V4_CanvasConfiguration {
    uiState.definition.canvasConfiguration
  }

  private var videoDevices: [Ldtx_Workspace_V4_VideoInputDevice] {
    uiState.definition.inputDevices.compactMap { wrapper in
      guard case .videoDevice(let device) = wrapper.definition else { return nil }
      return device
    }
  }

  private var frameRate: Int {
    let value = uiState.definition.canvasConfiguration.frameRate
    return value == 0 ? 60 : Int(value)
  }

  private var frameRateBinding: Binding<Int> {
    Binding(
      get: { frameRate },
      set: { value in
        var definition = uiState.definition
        definition.canvasConfiguration.frameRate = UInt32(value)
        uiState.definition = definition
      }
    )
  }

  private var landscapeBitRateBinding: Binding<Int> {
    bitRateBinding(\.landscapeVideoBitRate)
  }

  private var portraitBitRateBinding: Binding<Int> {
    bitRateBinding(\.portraitVideoBitRate)
  }

  private func bitRateBinding(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_CanvasConfiguration, UInt32>
  ) -> Binding<Int> {
    Binding(
      get: { Int(canvas[keyPath: keyPath]) },
      set: { value in
        let rate = UInt32(min(max(value, 100_000), 100_000_000))
        var definition = uiState.definition
        definition.canvasConfiguration[keyPath: keyPath] = rate
        uiState.definition = definition
      }
    )
  }

  private var ptsMasterBinding: Binding<UInt64?> {
    Binding(
      get: {
        canvas.hasPtsMasterVideoInputDeviceInternalID
          ? canvas.ptsMasterVideoInputDeviceInternalID : nil
      },
      set: { internalID in
        var definition = uiState.definition
        if let internalID {
          definition.canvasConfiguration.ptsMasterVideoInputDeviceInternalID = internalID
        } else {
          definition.canvasConfiguration.clearPtsMasterVideoInputDeviceInternalID()
        }
        uiState.definition = definition
      }
    )
  }
}
