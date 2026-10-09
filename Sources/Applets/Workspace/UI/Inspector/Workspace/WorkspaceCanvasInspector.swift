// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct WorkspaceCanvasInspector: View {
  let storeService: WorkspaceStoreService

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
        .disabled(storeService.isOutputActive)
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
      WorkspaceSelectionField(
        title: "PTS Master VFX Source", current: ptsMasterBinding.wrappedValue,
        options: videoDevices.map { .init(id: $0.internalID, name: $0.displayName) },
        emptyLabel: "Automatic", clearTitle: "Use Automatic Timing",
        isEditable: !storeService.isOutputActive,
        reportError: { storeService.reportError($0) },
        commit: { selected in
          guard !storeService.isOutputActive,
            selected == nil || videoDevices.contains(where: { $0.internalID == selected })
          else {
            throw WorkspaceSelectionError(
              message: "Select an available timing input while output is stopped.")
          }
          ptsMasterBinding.wrappedValue = selected
        })
    }
    .disabled(storeService.isOutputActive)

  }

  private var canvas: Ldtx_Workspace_V4_CanvasConfiguration {
    storeService.definition.canvasConfiguration
  }

  private var videoDevices: [Ldtx_Workspace_V4_VfxSourceComponent] {
    storeService.definition.videoComponents.compactMap { wrapper in
      guard case .vfxSource(let device) = wrapper.videoComponent else { return nil }
      return device
    }
  }

  private var frameRate: Int {
    let value = storeService.definition.canvasConfiguration.frameRate
    return value == 0 ? 60 : Int(value)
  }

  private var frameRateBinding: Binding<Int> {
    Binding(
      get: { frameRate },
      set: { value in
        var definition = storeService.definition
        definition.canvasConfiguration.frameRate = UInt32(value)
        storeService.definition = definition
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
        var definition = storeService.definition
        definition.canvasConfiguration[keyPath: keyPath] = rate
        storeService.definition = definition
      }
    )
  }

  private var ptsMasterBinding: Binding<UInt64?> {
    Binding(
      get: {
        canvas.hasPtsMasterVfxSourceInternalID
          ? canvas.ptsMasterVfxSourceInternalID : nil
      },
      set: { internalID in
        var definition = storeService.definition
        if let internalID {
          definition.canvasConfiguration.ptsMasterVfxSourceInternalID = internalID
        } else {
          definition.canvasConfiguration.clearPtsMasterVfxSourceInternalID()
        }
        storeService.definition = definition
      }
    )
  }
}
