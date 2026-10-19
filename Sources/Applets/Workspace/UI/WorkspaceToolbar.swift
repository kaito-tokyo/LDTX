// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletModel
import LDTXWorkspaceBundleFormat
import QuickLookThumbnailing
import SwiftUI

public struct WorkspaceToolbar: ToolbarContent {
  let stateService: WorkspaceDocument
  let document: (any WorkspaceDocumentContext)?
  let runtimeWorkspace: () -> WorkspaceV4Bundle?
  let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  let runInference: () -> Void

  public init(
    stateService: WorkspaceDocument, document: (any WorkspaceDocumentContext)?,
    runtimeWorkspace: @escaping () -> WorkspaceV4Bundle?,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)?,
    runInference: @escaping () -> Void
  ) {
    self.stateService = stateService
    self.document = document
    self.runtimeWorkspace = runtimeWorkspace
    self.runtimeActions = runtimeActions
    self.runInference = runInference
  }

  public var body: some ToolbarContent {
    ToolbarItem(id: "workspace.toggleSidebar", placement: .navigation) {
      Button("Toggle Sidebar", systemImage: "sidebar.left") {
        stateService.isSidebarVisible.toggle()
      }
      .accessibilityIdentifier("workspace.toggleSidebar")
    }
    ToolbarItem(id: "workspace.stopOutput", placement: .navigation) {
      Button("Stop Output", systemImage: "stop.fill") {
        Task { await runtimeActions()?.stopOutput() }
      }
      .disabled(!stateService.recordingState.canStop || stateService.isClosed)
      .accessibilityIdentifier("workspace.stopOutput")
    }
    ToolbarItem(id: "workspace.startPauseOutput", placement: .navigation) {
      Button(
        stateService.recordingState == .recording ? "Pause Output" : "Start Output",
        systemImage: stateService.recordingState == .recording ? "pause.fill" : "play.fill"
      ) {
        Task {
          await runtimeActions()?.toggleOutput(stateService: stateService, document: document)
        }
      }
      .disabled(
        stateService.isClosed
          || !((stateService.recordingState.canStart && document?.fileURL != nil)
            || stateService.recordingState == .recording)
      )
      .accessibilityIdentifier("workspace.startPauseOutput")
    }
    ToolbarItem(id: "workspace.captureScreenshots", placement: .navigation) {
      WorkspaceScreenshotButton(stateService: stateService, runtimeActions: runtimeActions)
    }
    ToolbarItem(id: "workspace.runInference", placement: .primaryAction) {
      Button("Run Inference", systemImage: "sparkles", action: runInference)
        .disabled(
          stateService.isClosed || stateService.isInferring || runtimeActions() == nil
            || stateService.inferenceRequest(document: document, workspace: runtimeWorkspace())
              == nil
        )
        .accessibilityIdentifier("workspace.runInference")
    }
    ToolbarItem(id: "workspace.toggleInspector", placement: .primaryAction) {
      Button("Toggle Inspector", systemImage: "sidebar.right") {
        stateService.isInspectorVisible.toggle()
      }
      .accessibilityIdentifier("workspace.toggleInspector")
    }
  }
}

private struct WorkspaceScreenshotButton: View {
  let stateService: WorkspaceDocument
  let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  @State private var result: WorkspaceScreenshotResult?

  var body: some View {
    Button("Capture Screenshot(s)", systemImage: "camera") {
      result = WorkspaceScreenshotResult.capture(using: runtimeActions())
    }
    .disabled(stateService.isClosed)
    .accessibilityIdentifier("workspace.captureScreenshots")
    .popover(item: $result) {
      ScreenshotResultView(title: $0.title, message: $0.message, screenshots: $0.screenshots)
    }
    .onChange(of: stateService.isClosed) { _, closed in if closed { result = nil } }
  }
}

struct WorkspaceScreenshotResult: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  let screenshots: [WorkspaceScreenshot]

  @MainActor static func capture(using actions: (any WorkspaceRuntimeActions)?) -> Self {
    do {
      guard let actions else {
        throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
      }
      let files = try actions.captureScreenshots().filter { $0.programCanvas != nil }
      return Self(
        title: "Screenshots saved",
        message: files.isEmpty
          ? "No Program screenshots were available."
          : files.count == 1
            ? "Saved 1 Program screenshot." : "Saved \(files.count) Program screenshots.",
        screenshots: files.filter { $0.programCanvas == .landscape })
    } catch {
      return Self(
        title: "Screenshot could not be captured",
        message: error.localizedDescription, screenshots: [])
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
