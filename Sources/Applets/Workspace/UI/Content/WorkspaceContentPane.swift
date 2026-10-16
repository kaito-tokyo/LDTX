// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgramRuntime
import LDTXWorkspaceAppletModel
import Observation
import SwiftUI

public struct WorkspaceContentPane: View {
  let stateService: WorkspaceStateService
  let appletData: WorkspaceAppletData
  let peakMeter: ProgramAudioPeakMeter
  let reportError: (Error) -> Void
  let pairedPreview: ProgramCanvasPairedPreview
  let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  let layout: WorkspaceContentLayout

  public init(
    stateService: WorkspaceStateService, appletData: WorkspaceAppletData,
    peakMeter: ProgramAudioPeakMeter, reportError: @escaping (Error) -> Void,
    pairedPreview: ProgramCanvasPairedPreview,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)? = { nil },
    layout: WorkspaceContentLayout = WorkspaceContentLayout()
  ) {
    self.stateService = stateService
    self.appletData = appletData
    self.peakMeter = peakMeter
    self.reportError = reportError
    self.pairedPreview = pairedPreview
    self.runtimeActions = runtimeActions
    self.layout = layout
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
    return ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        MasterVolumeEditor(
          stateService: stateService, appletData: appletData, peakMeter: peakMeter,
          reportError: reportError, runtimeActions: runtimeActions)
        AudioMixEditor(
          stateService: stateService, appletData: appletData, peakMeter: peakMeter,
          reportError: reportError, runtimeActions: runtimeActions)
        Picker("Video Layers", selection: $layout.isPortrait) {
          Text("Landscape Video Layers").tag(false)
          Text("Portrait Video Layers").tag(true)
        }
        .pickerStyle(.segmented)
        ZStack(alignment: .topLeading) {
          videoLayers(.landscape, isVisible: !layout.isPortrait)
          videoLayers(.portrait, isVisible: layout.isPortrait)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func videoLayers(_ target: WorkspaceCanvasTarget, isVisible: Bool) -> some View {
    VideoLayersEditor(stateService: stateService, appletData: appletData, target: target)
      .frame(height: isVisible ? nil : 0, alignment: .top)
      .clipped()
      .opacity(isVisible ? 1 : 0)
      .disabled(!isVisible)
      .accessibilityHidden(!isVisible)
  }
}

@MainActor @Observable
public final class WorkspaceContentLayout {
  public init() {}

  var isPortrait = false
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

#if DEBUG
  #Preview("Workspace Content", traits: .fixedLayout(width: 480, height: 560)) {
    PreviewWorkspaceContentPaneController(hasProgram: true)
  }

  #Preview("Workspace Content — No Program", traits: .fixedLayout(width: 480, height: 560)) {
    PreviewWorkspaceContentPaneController(hasProgram: false)
  }
#endif
