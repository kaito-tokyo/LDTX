// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletUI
import QuickLookThumbnailing
import SwiftUI

struct WorkspaceToolbar: ToolbarContent {
  let state: WorkspaceViewState

  var body: some ToolbarContent {
    ToolbarItem(id: "workspace.toggleSidebar", placement: .navigation) {
      Button("Toggle Sidebar", systemImage: "sidebar.left") { state.toggleSidebar() }
        .accessibilityIdentifier("workspace.toggleSidebar")
    }
    ToolbarItem(id: "workspace.stopOutput", placement: .navigation) {
      Button("Stop Output", systemImage: "stop.fill") { state.stopOutput() }
        .disabled(!state.stateService.recordingState.canStop || state.isClosed)
        .accessibilityIdentifier("workspace.stopOutput")
    }
    ToolbarItem(id: "workspace.startPauseOutput", placement: .navigation) {
      Button(
        state.stateService.recordingState == .recording ? "Pause Output" : "Start Output",
        systemImage: state.stateService.recordingState == .recording ? "pause.fill" : "play.fill"
      ) { state.toggleOutput() }
      .disabled(
        state.isClosed
          || !((state.stateService.recordingState.canStart && state.document?.fileURL != nil)
            || state.stateService.recordingState == .recording)
      )
      .accessibilityIdentifier("workspace.startPauseOutput")
    }
    ToolbarItem(id: "workspace.captureScreenshots", placement: .navigation) {
      WorkspaceScreenshotButton(state: state)
    }
    ToolbarItem(id: "workspace.runInference", placement: .primaryAction) {
      Button("Run Inference", systemImage: "sparkles") { state.runInference() }
        .disabled(
          state.presentation.isInferring || state.inferenceRequest == nil
            || state.runtimeActions() == nil || state.isClosed
        )
        .accessibilityIdentifier("workspace.runInference")
    }
    ToolbarItem(id: "workspace.toggleInspector", placement: .primaryAction) {
      Button("Toggle Inspector", systemImage: "sidebar.right") { state.toggleInspector() }
        .accessibilityIdentifier("workspace.toggleInspector")
    }
  }
}

private struct WorkspaceScreenshotButton: View {
  let state: WorkspaceViewState

  var body: some View {
    @Bindable var presentation = state.presentation
    Button("Capture Screenshot(s)", systemImage: "camera") { state.captureScreenshots() }
      .disabled(state.isClosed)
      .accessibilityIdentifier("workspace.captureScreenshots")
      .popover(item: $presentation.screenshot) { result in
        ScreenshotResultView(
          title: result.title, message: result.message, screenshots: result.screenshots)
      }
  }
}

private struct ScreenshotResultView: View {
  let title: String
  let message: String
  let screenshots: [WorkspaceScreenshot]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      Text(message)
      ForEach(screenshots, id: \.url) { screenshot in
        Button {
          NSWorkspace.shared.open(screenshot.url)
        } label: {
          HStack(spacing: 10) {
            FileIcon(url: screenshot.url)
            Text(screenshot.url.lastPathComponent)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(screenshot.url.path)
        .onDrag { NSItemProvider(object: screenshot.url as NSURL) }
      }
    }
    .padding()
    .frame(width: screenshots.isEmpty ? 280 : 360, alignment: .leading)
  }

  private struct FileIcon: View {
    let url: URL
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?

    var body: some View {
      Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path))
        .resizable()
        .scaledToFit()
        .frame(width: 32, height: 32)
        .task(id: url) {
          image = nil
          let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 32, height: 32), scale: displayScale,
            representationTypes: .all)
          request.iconMode = true
          guard
            let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(
              for: request),
            !Task.isCancelled
          else { return }
          image = representation.nsImage
        }
    }
  }
}

