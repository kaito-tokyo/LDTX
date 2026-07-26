// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXInternalProtocols
import LDTXProgramRuntime
import LDTXYouTubeAuth
import SwiftUI

enum AppFeatureComposition {
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

  @MainActor static func makeProgramRuntime(
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    programPreferencesState: ProgramPreferencesState = ProgramPreferencesState()
  ) -> ProgramRuntime {
    ProgramRuntime(
      captureSessionCoordinator: captureSessionCoordinator,
      backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
      programPreferencesState: programPreferencesState
    )
  }

  static func modelSettingsTab() -> AnyView? {
    AnyView(VisionModelSettingsView())
  }
}
