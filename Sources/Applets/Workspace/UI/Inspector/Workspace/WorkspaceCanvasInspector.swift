// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import SwiftUI

struct WorkspaceCanvasInspector: View {
  @Environment(\.undoManager) private var undoManager
  let stateService: WorkspaceDocument

  var body: some View {
    Form {
      formContent
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var formContent: some View {
    Section("Canvas") {
      Stepper("Frame Rate: \(frameRate)", value: frameRateBinding, in: 1...240)
        .disabled(stateService.isOutputActive)
      LabeledContent("Landscape Profile", value: canvas.landscapeProfileID ?? "")
      LabeledContent("Portrait Profile", value: canvas.portraitProfileID ?? "")
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
      Picker("PTS Master VFX Source", selection: ptsMasterBinding) {
        Text("Automatic").tag(Int64?.none)
        ForEach(videoDevices, id: \.internalID) { device in
          Text(device.displayName ?? "").tag(device.internalID)
        }
        if let selected = ptsMasterBinding.wrappedValue,
          !videoDevices.contains(where: { $0.internalID == selected })
        {
          Text("Unavailable").tag(Optional(selected))
        }
      }
      .pickerStyle(.menu)
    }
    .disabled(stateService.isOutputActive)

  }

  private var canvas: Ldtx_Workspace_V4_CanvasConfiguration {
    stateService.workspaceDefinition.canvasConfiguration ?? .init()
  }

  private var videoDevices: [Ldtx_Workspace_V4_VfxSourceComponent] {
    stateService.workspaceDefinition.videoComponents.compactMap { wrapper in
      guard case .vfxSource(let device) = wrapper.videoComponent else { return nil }
      return device
    }
  }

  private var frameRate: Int {
    let value = stateService.workspaceDefinition.canvasConfiguration?.frameRate ?? 0
    return value == 0 ? 60 : Int(value)
  }

  private var frameRateBinding: Binding<Int> {
    Binding(
      get: { frameRate },
      set: { value in
        var definition = stateService.workspaceDefinition
        var configuration = definition.canvasConfiguration ?? .init()
        configuration.frameRate = UInt32(value)
        definition.canvasConfiguration = configuration
        stateService.editWorkspace(undoManager: undoManager) { workspace in
          workspace.definition = definition
        }
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
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_CanvasConfiguration, UInt32?>
  ) -> Binding<Int> {
    Binding(
      get: { Int(canvas[keyPath: keyPath] ?? 0) },
      set: { value in
        let rate = UInt32(min(max(value, 100_000), 100_000_000))
        var definition = stateService.workspaceDefinition
        var configuration = definition.canvasConfiguration ?? .init()
        configuration[keyPath: keyPath] = rate
        definition.canvasConfiguration = configuration
        stateService.editWorkspace(undoManager: undoManager) { workspace in
          workspace.definition = definition
        }
      }
    )
  }

  private var ptsMasterBinding: Binding<Int64?> {
    Binding(
      get: {
        canvas.ptsMasterVfxSourceInternalID
      },
      set: { internalID in
        var definition = stateService.workspaceDefinition
        var configuration = definition.canvasConfiguration ?? .init()
        if let internalID {
          configuration.ptsMasterVfxSourceInternalID = internalID
        } else {
          configuration.ptsMasterVfxSourceInternalID = nil
        }
        definition.canvasConfiguration = configuration
        stateService.editWorkspace(undoManager: undoManager) { workspace in
          workspace.definition = definition
        }
      }
    )
  }
}
