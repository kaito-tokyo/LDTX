// SPDX-FileCopyrightText: 2026 Kaito Udagawa
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXBackgroundSegmentation
import LDTXInternalProtocols
import LDTXProgramRuntime
import LDTXRecordPlayerApplet
import LDTXSettingsApplet
import LDTXTaskQueue
import LDTXVisionProgrammerApplet
import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletUI
import LDTXYouTubeAuth
import MetalKit
import SwiftUI

@main
@MainActor
struct LDTXApp: App {
  @State private var workspaceResources: [UUID: WorkspaceRuntimeResources] = [:]

  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  init() {
    if let bundleIdentifier = Bundle.main.bundleIdentifier,
      let directory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    {
      YouTubeAuthorizationService.configureApplicationStorage(
        applicationSupportDirectory: directory, bundleIdentifier: bundleIdentifier)
    }
  }

  var body: some Scene {
    // Read State here so resource registration updates the Scene's editor
    // closure; reading only inside DocumentGroup leaves its initial snapshot.
    let currentResources = workspaceResources
    let resourceStorage = $workspaceResources
    DocumentGroup(allowCreating: false) { (document: RecordPlayerDocument) in
      RecordPlayerDocumentContent(document: document)
    } makeDocument: { configuration, _ in
      RecordPlayerDocument(configuration: configuration)
    }
    .defaultSize(width: 960, height: 600)
    .windowToolbarStyle(.unified)
    .commands {
      RecordPlayerCommands()
    }

    DocumentGroup { (document: WorkspaceDocument) in
      let resources = currentResources[document.runtimeID]
      WorkspaceDocumentContent(
        document: document,
        landscapeRuntime: resources?.landscape,
        portraitRuntime: resources?.portrait,
        metalView: resources?.metalView,
        captureSessionCoordinator: resources?.capture)
    } makeDocument: { configuration, _ in
      let resources = resourceStorage
      let document = WorkspaceDocument(configuration: configuration) { id in
        resources.wrappedValue.removeValue(forKey: id)
      }
      resources.wrappedValue[document.runtimeID] = WorkspaceRuntimeResources()
      return document
    }
    .defaultSize(width: 1062, height: 700)
    .windowToolbarStyle(.unified)
    .commands {
      WorkspaceCommands()
      TextFormattingCommands()
    }

    Settings {
      SettingsRootView()
    }
    .defaultLaunchBehavior(.suppressed)

    Window("Vision Programmer", id: VisionProgrammerView.id) {
      VisionProgrammerView()
    }
    .defaultSize(width: 700, height: 500)
    .windowToolbarStyle(.unified)
    .defaultLaunchBehavior(.suppressed)
    .commands {
      VisionProgrammerCommands()
    }
  }
}

/// Resources retained by App State until the Workspace finishes shutting down.
@MainActor
private struct WorkspaceRuntimeResources {
  let landscape: ProgramRuntime
  let portrait: ProgramRuntime
  let metalView: MTKView
  let capture: WorkspaceCaptureSessionCoordinator

  init() {
    let capture = WorkspaceCaptureSessionCoordinator()
    let backgroundRemoval: BackgroundRemovalPreprocessorFactory = { device, textureCache in
      BackgroundRemovalVideoInputPreprocessor(device: device, textureCache: textureCache)
    }
    self.capture = capture
    landscape = ProgramRuntime(
      captureSessionCoordinator: capture,
      backgroundRemovalPreprocessorFactory: backgroundRemoval
    )
    portrait = ProgramRuntime(
      captureSessionCoordinator: capture,
      backgroundRemovalPreprocessorFactory: backgroundRemoval
    )
    metalView = MTKView(frame: .zero, device: nil)
    metalView.isPaused = true
  }
}
