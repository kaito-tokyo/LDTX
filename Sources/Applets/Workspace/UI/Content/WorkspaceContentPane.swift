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
  let layout = WorkspaceContentLayout()
  @State private var dragStart: CGFloat?

  public init(
    stateService: WorkspaceStateService, appletData: WorkspaceAppletData,
    peakMeter: ProgramAudioPeakMeter, reportError: @escaping (Error) -> Void,
    pairedPreview: ProgramCanvasPairedPreview,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)? = { nil }
  ) {
    self.stateService = stateService
    self.appletData = appletData
    self.peakMeter = peakMeter
    self.reportError = reportError
    self.pairedPreview = pairedPreview
    self.runtimeActions = runtimeActions
  }

  public var body: some View {
    @Bindable var layout = layout
    GeometryReader { geometry in
      let height = min(layout.previewHeight, max(0, geometry.size.height - 1))
      VStack(spacing: 0) {
        pairedPreview.content
          .frame(height: height)
        Divider()
          .overlay {
            Color.clear
              .frame(height: 9)
              .contentShape(Rectangle())
              .pointerStyle(.rowResize)
              .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("WorkspaceContent"))
                  .onChanged { value in
                    if dragStart == nil { dragStart = height }
                    layout.resizePreview(
                      to: min(
                        max(0, (dragStart ?? height) + value.translation.height),
                        max(0, geometry.size.height - 1)))
                  }
                  .onEnded { _ in dragStart = nil }
              )
              .accessibilityLabel("Preview height")
              .accessibilityValue(Text("\(Int(height)) points"))
              .accessibilityAdjustableAction { direction in
                layout.resizePreview(
                  to: min(
                    max(0, height + (direction == .increment ? 20 : -20)),
                    max(0, geometry.size.height - 1)))
              }
          }
        ScrollView {
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
              VideoLayersEditor(
                stateService: stateService, appletData: appletData, target: .landscape
              )
              .frame(height: layout.isPortrait ? 0 : nil, alignment: .top)
              .clipped()
              .opacity(layout.isPortrait ? 0 : 1)
              .disabled(layout.isPortrait)
              .accessibilityHidden(layout.isPortrait)
              VideoLayersEditor(
                stateService: stateService, appletData: appletData, target: .portrait
              )
              .frame(height: layout.isPortrait ? nil : 0, alignment: .top)
              .clipped()
              .opacity(layout.isPortrait ? 1 : 0)
              .disabled(!layout.isPortrait)
              .accessibilityHidden(!layout.isPortrait)
            }
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
      }
    }
    .coordinateSpace(name: "WorkspaceContent")
    .frame(minWidth: 480, minHeight: 120)
    .onChange(of: stateService.externalID, initial: true) { _, externalID in
      layout.restore(externalID: externalID)
    }
  }
}

@MainActor @Observable
final class WorkspaceContentLayout {
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
