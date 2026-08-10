// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXCapture
import LDTXInternalProtocols
import LDTXProgramRuntime
import LDTXTaskQueue
import LDTXWorkspace
import LDTXYouTubeAuth
import SwiftUI

@MainActor
final class TinyAppFeatureProvider: AppFeatureProvider {
  let configuration = AppConfiguration(
    bundleIdentifier: "tokyo.kaito.ldtx.LDTXTiny",
    youtubeOAuthKeychainService: "tokyo.kaito.ldtx.LDTXTiny.youtube-auth",
    mcpServerName: "tokyo.kaito.ldtx.tiny.recording",
    xpcServiceName: "tokyo.kaito.ldtx.LDTXTiny.YouTubeOutputServiceProcess", uiFeatures: [])
  let workspaceFeatureAvailability = WorkspaceFeatureAvailability.aiFree
  let backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil

  func makeYouTubeClientService() -> YouTubeClientService {
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

  func makeProgramRuntime(
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    programPreferencesState: ProgramPreferencesState,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  ) -> ProgramRuntime {
    ProgramRuntime(
      captureSessionCoordinator: captureSessionCoordinator,
      programPreferencesState: programPreferencesState,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry
    )
  }

  func makeVisionFeature(workspaceResourceQueue: WorkspaceResourceQueue)
    -> any WorkspaceVisionFeatureProviding
  {
    TinyWorkspaceVisionFeature(workspaceResourceQueue: workspaceResourceQueue)
  }

  func modelSettingsTab() -> AnyView? { nil }
}
