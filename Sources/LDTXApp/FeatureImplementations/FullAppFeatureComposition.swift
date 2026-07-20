// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXAutomation
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXInternalProtocols
import LDTXProgramRuntime
import LDTXYouTubeAuth
import SwiftUI

enum AppFeatureComposition {
  static let automationServiceIdentity = LDTXAutomationService.full
  static let workspaceFeatureAvailability = WorkspaceFeatureAvailability.all
  @MainActor static let backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = {
    device, textureCache in
    BackgroundRemovalVideoInputPreprocessor(device: device, textureCache: textureCache)
  }

  @MainActor static func makeYouTubeClientService() -> YouTubeClientService {
    YouTubeClientService(
      authorizationService: YouTubeAuthorizationService(
        authorizationStore: YouTubeAuthorizationStore(
          service: "tokyo.kaito.ldtx.youtube-auth"
        ),
        oauthClientStore: OAuthClientConfigurationStore(
          service: "tokyo.kaito.ldtx.oauth-client"
        )
      )
    )
  }

  @MainActor static func makeActiveProgramRuntime(
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  ) -> ActiveProgramRuntime {
    ActiveProgramRuntime(
      captureSessionCoordinator: captureSessionCoordinator,
      backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory
    )
  }

  static func modelSettingsTab() -> AnyView? {
    AnyView(VisionModelSettingsView())
  }
}
