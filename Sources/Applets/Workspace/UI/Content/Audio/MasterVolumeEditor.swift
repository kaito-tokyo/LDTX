// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgramRuntime
import LDTXProtos
import LDTXWorkspaceAppletModel
import SwiftUI

struct MasterVolumeEditor: View {
  @Environment(\.undoManager) private var undoManager
  let stateService: WorkspaceDocument
  let appletData: WorkspaceAppletData
  let peakMeter: ProgramAudioPeakMeter
  let reportError: (Error) -> Void
  var runtimeActions: () -> (any WorkspaceRuntimeActions)? = { nil }

  private var programID: Int64? {
    appletData.selectedProgram(
      in: stateService.workspaceDefinition, for: stateService.localStateURL)?.internalID
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Master Volumes").fontWeight(.semibold)
      master(target: .landscape, name: "Landscape", symbol: "rectangle")
      master(target: .portrait, name: "Portrait", symbol: "rectangle.portrait")
      HStack {
        Text("Monitor Volume")
        Slider(
          value: Binding(
            get: {
              stateService.localStateURL.flatMap { appletData.state(for: $0).monitorVolume } ?? 0
            },
            set: { _ = setMonitorVolume($0) }), in: -80...20
        )
        .accessibilityLabel("Monitor Volume")
        .disabled(stateService.localStateURL == nil)
      }
      Divider()
    }
  }

  private func master(target: WorkspaceCanvasTarget, name: String, symbol: String) -> some View {
    let id = programID
    let value = Binding<Ldtx_Workspace_V4_Rational32>(
      get: {
        id.flatMap {
          guard let preference = stateService.workspacePreferences[keyPath: target.preferences][$0],
            preference.hasAudioMasterVolumeDecibels
          else { return nil }
          return preference.audioMasterVolumeDecibels
        } ?? .with { $0.set(num: 0, den: 10) }
      },
      set: { value in
        guard let id,
          stateService.workspaceDefinition.programs.contains(where: { $0.internalID == id })
        else { return }
        stateService.editWorkspace(undoManager: undoManager) { workspace in
          workspace.preferences[keyPath: target.preferences][id, default: .init()]
            .audioMasterVolumeDecibels = value
        }
      })
    return HStack(spacing: 8) {
      Image(systemName: symbol).frame(width: 20).accessibilityLabel(name)
      AudioChannelControl(
        value: Binding(
          get: { value.wrappedValue.double },
          set: {
            if let encoded = try? Rational32DecibelEncoding.encode($0) {
              value.wrappedValue = encoded
            }
          }),
        peakProvider: {
          peakMeter.peak(
            for: target.preferences == WorkspaceCanvasTarget.landscape.preferences
              ? .landscape : .portrait)
        },
        showsValue: false, title: name + " Volume"
      )
      AudioDecibelField(value: value).frame(width: 60).id(id)
      Text("dB")
    }
    .disabled(id == nil)
  }

  @discardableResult
  func setMonitorVolume(_ value: Double) -> Bool {
    guard let url = stateService.localStateURL else { return false }
    do {
      let volume = try Rational32DecibelEncoding.encode(value).double
      appletData.updateState(for: url) { $0.monitorVolume = volume }
      runtimeActions()?.synchronizeAudioMonitor()
      return true
    } catch {
      reportError(error)
      return false
    }
  }
}

struct AudioDecibelField: View {
  @Binding var value: Ldtx_Workspace_V4_Rational32
  @State private var draft = ""
  @State private var hasInvalidDraft = false
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField(
      "Master volume in dB",
      text: Binding(
        get: { draft },
        set: { text in
          draft = text
          guard let parsed = try? RationalParseStrategy().parse(text),
            (-80...20).contains(parsed.double),
            let encoded = try? Rational32DecibelEncoding.encode(parsed.double)
          else {
            hasInvalidDraft = true
            return
          }
          hasInvalidDraft = false
          value = encoded
        })
    )
    .textFieldStyle(.roundedBorder)
    .focused($isFocused)
    .onChange(of: value, initial: true) { _, new in
      if !hasInvalidDraft && !isFocused { draft = RationalFormatStyle().format(new) }
    }
    .onChange(of: isFocused) { _, focused in
      if !focused && !hasInvalidDraft { draft = RationalFormatStyle().format(value) }
    }
  }
}
