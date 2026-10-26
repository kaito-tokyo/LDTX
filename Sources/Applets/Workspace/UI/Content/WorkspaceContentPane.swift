// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletModel
import Observation
import SwiftUI

public struct WorkspaceContentPane: View {
  let stateService: WorkspaceDocument
  let appletData: WorkspaceAppletData
  let peakMeter: any ProgramAudioPeakMeterPresenting
  let reportError: (Error) -> Void
  let pairedPreview: ProgramCanvasPairedPreview
  let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  @State var layout = WorkspaceContentLayout()
  @State private var landscapeEditor: VideoLayersEditorState
  @State private var portraitEditor: VideoLayersEditorState

  public init(
    stateService: WorkspaceDocument, appletData: WorkspaceAppletData,
    peakMeter: any ProgramAudioPeakMeterPresenting, reportError: @escaping (Error) -> Void,
    pairedPreview: ProgramCanvasPairedPreview,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)? = { nil }
  ) {
    self.stateService = stateService
    self.appletData = appletData
    self.peakMeter = peakMeter
    self.reportError = reportError
    self.pairedPreview = pairedPreview
    self.runtimeActions = runtimeActions
    _landscapeEditor = State(
      initialValue: VideoLayersEditorState(
        stateService: stateService, appletData: appletData, target: .landscape))
    _portraitEditor = State(
      initialValue: VideoLayersEditorState(
        stateService: stateService, appletData: appletData, target: .portrait))
  }

  public var body: some View {
    GeometryReader { geometry in
      let maximum = max(0, geometry.size.height - 1)
      let height = min(layout.previewHeight, maximum)
      VStack(spacing: 0) {
        pairedPreview.content.frame(height: height)
        WorkspaceDivider("Preview height", axis: .vertical, value: height) {
          layout.resizePreview(to: min(maximum, max(0, $0)))
        }
        editors.frame(maxHeight: .infinity)
      }
    }
    .frame(minWidth: 480, minHeight: 120)
    .onChange(of: stateService.externalID, initial: true) { _, id in
      layout.restore(externalID: id)
    }
  }

  private var editors: some View {
    @Bindable var layout = layout
    return VStack(spacing: 0) {
      Picker("Content editor", selection: $layout.selectedEditor) {
        Text("Audio").tag(WorkspaceContentLayout.Editor.audio)
        Text("Landscape").tag(WorkspaceContentLayout.Editor.landscape)
        Text("Portrait").tag(WorkspaceContentLayout.Editor.portrait)
      }
      .pickerStyle(.segmented)
      .padding(8)
      List {
        switch layout.selectedEditor {
        case .audio:
          Section {
            MasterVolumeEditor(
              stateService: stateService, appletData: appletData, peakMeter: peakMeter,
              reportError: reportError, runtimeActions: runtimeActions)
            AudioMixEditor(
              stateService: stateService, appletData: appletData, peakMeter: peakMeter,
              reportError: reportError, runtimeActions: runtimeActions)
          }
        case .landscape:
          VideoLayersEditor(editor: landscapeEditor)
        case .portrait:
          VideoLayersEditor(editor: portraitEditor)
        }
      }
      .listStyle(.inset)
    }
  }
}

@MainActor @Observable
final class WorkspaceContentLayout {
  init() {}

  enum Editor: Hashable {
    case audio, landscape, portrait
  }

  var selectedEditor: Editor = .audio
  var previewHeight: CGFloat = 280
  private var persistenceKey: String?

  func restore(externalID: String?) {
    let key = externalID.map { "WorkspaceContentPane.\($0).previewHeight" }
    guard key != persistenceKey else { return }
    persistenceKey = key
    previewHeight =
      key.flatMap { UserDefaults.standard.object(forKey: $0) as? Double }
      .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 280
    if let key, UserDefaults.standard.object(forKey: key) == nil,
      let externalID,
      let frames = UserDefaults.standard.stringArray(
        forKey: "NSSplitView Subview Frames WorkspaceContentPane.\(externalID)"),
      let first = frames.first
    {
      let fields = first.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      if fields.count >= 4, let height = Double(fields[3]), height.isFinite, height >= 0 {
        previewHeight = height
        UserDefaults.standard.set(height, forKey: key)
      }
    }
  }

  func resizePreview(to height: CGFloat) {
    guard height.isFinite else { return }
    previewHeight = max(0, height)
    if let persistenceKey {
      UserDefaults.standard.set(Double(previewHeight), forKey: persistenceKey)
    }
  }
}
