// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXBackgroundSegmentation
import LDTXInternalProtocols
import LDTXProgramRuntime
import LDTXTaskQueue
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletUI
import MetalKit

/// Component tests are composition roots for their independently constructed windows.
@MainActor
struct WorkspaceRuntimeFixture {
  let capture = WorkspaceCaptureSessionCoordinator()
  let landscape: ProgramRuntime
  let portrait: ProgramRuntime
  let metalView = MTKView(frame: .zero, device: nil)

  init() {
    let backgroundRemoval: BackgroundRemovalPreprocessorFactory = { device, cache in
      BackgroundRemovalVideoInputPreprocessor(device: device, textureCache: cache)
    }
    landscape = ProgramRuntime(
      captureSessionCoordinator: capture, backgroundRemovalPreprocessorFactory: backgroundRemoval)
    portrait = ProgramRuntime(
      captureSessionCoordinator: capture, backgroundRemovalPreprocessorFactory: backgroundRemoval)
    metalView.isPaused = true
  }
}

extension WorkspaceRuntimeCoordinator {
  convenience init(document: WorkspaceDocument, appletData: WorkspaceAppletData = .shared) {
    let resources = WorkspaceRuntimeFixture()
    self.init(
      document: document, appletData: appletData,
      landscapeRuntime: resources.landscape, portraitRuntime: resources.portrait,
      metalView: resources.metalView, captureSessionCoordinator: resources.capture)
  }

  convenience init(
    stateService: WorkspaceDocument, persistenceCoordinator: WorkspaceV4PersistenceCoordinator,
    appletData: WorkspaceAppletData, document: any WorkspaceDocumentContext
  ) {
    let resources = WorkspaceRuntimeFixture()
    self.init(
      stateService: stateService, persistenceCoordinator: persistenceCoordinator,
      appletData: appletData, document: document,
      landscapeRuntime: resources.landscape, portraitRuntime: resources.portrait,
      metalView: resources.metalView, captureSessionCoordinator: resources.capture,
      releaseRuntimeResources: {})
  }
}

extension WorkspaceDocumentContent {
  init(document: WorkspaceDocument) {
    let resources = WorkspaceRuntimeFixture()
    self.init(
      document: document, landscapeRuntime: resources.landscape,
      portraitRuntime: resources.portrait,
      metalView: resources.metalView, captureSessionCoordinator: resources.capture)
  }
}

extension WorkspaceDocumentConnection {
  convenience init(document: WorkspaceDocument) {
    self.init(
      document: document, runtimeCoordinator: WorkspaceRuntimeCoordinator(document: document))
  }
}
