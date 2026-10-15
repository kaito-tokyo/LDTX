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
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var workspaceResources:
    [UUID: (
      landscape: ProgramRuntime, portrait: ProgramRuntime, metalView: MTKView,
      capture: WorkspaceCaptureSessionCoordinator, updates: LowFrequencyUpdateRegistry
    )] = [:]

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
      let resources = workspaceResources[document.runtimeID]
      WorkspaceDocumentContent(
        document: document,
        landscapeRuntime: resources?.landscape,
        portraitRuntime: resources?.portrait,
        metalView: resources?.metalView,
        captureSessionCoordinator: resources?.capture,
        lowFrequencyUpdateRegistry: resources?.updates)
    } makeDocument: { configuration, _ in
      let resources = $workspaceResources
      let document = WorkspaceDocument(configuration: configuration) { id in
        resources.wrappedValue.removeValue(forKey: id)
      }
      let capture = WorkspaceCaptureSessionCoordinator()
      let updates = LowFrequencyUpdateRegistry()
      let backgroundRemoval: BackgroundRemovalPreprocessorFactory = { device, textureCache in
        BackgroundRemovalVideoInputPreprocessor(device: device, textureCache: textureCache)
      }
      let landscape = ProgramRuntime(
        captureSessionCoordinator: capture,
        backgroundRemovalPreprocessorFactory: backgroundRemoval, lowFrequencyUpdateRegistry: updates
      )
      let portrait = ProgramRuntime(
        captureSessionCoordinator: capture,
        backgroundRemovalPreprocessorFactory: backgroundRemoval, lowFrequencyUpdateRegistry: updates
      )
      let metalView = MTKView(frame: .zero, device: nil)
      metalView.isPaused = true
      resources.wrappedValue[document.runtimeID] = (
        landscape, portrait, metalView, capture, updates
      )
      return document
    }
    .windowToolbarStyle(.unified)
    .commands {
      WorkspaceCommands()
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
