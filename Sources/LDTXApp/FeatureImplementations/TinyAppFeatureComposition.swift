// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXCapture
import LDTXInternalProtocols
import LDTXProgramRuntime
import LDTXYouTubeAuth
import SwiftUI

enum AppFeatureComposition {
  static let workspaceFeatureAvailability = WorkspaceFeatureAvailability.aiFree
  @MainActor static let backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil

  @MainActor static func makeYouTubeClientService() -> YouTubeClientService {
    YouTubeClientService(
      authorizationService: YouTubeAuthorizationService(
        authorizationStore: YouTubeAuthorizationStore(
          service: "tokyo.kaito.ldtx.LDTXTiny.youtube-auth"
        ),
        oauthClientStore: OAuthClientConfigurationStore(
          service: "tokyo.kaito.ldtx.LDTXTiny.oauth-client"
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
      programPreferencesState: programPreferencesState
    )
  }

  static func modelSettingsTab() -> AnyView? {
    nil
  }
}
