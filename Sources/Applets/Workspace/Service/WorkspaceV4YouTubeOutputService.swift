// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletModel
import LDTXYouTubeRTMPS

public enum WorkspaceV4YouTubeOutputError: LocalizedError, Equatable {
  case missingLandscapeStreamKey
  case missingPortraitStreamKey
  case unsupportedIngestMode

  public var errorDescription: String? {
    switch self {
    case .missingLandscapeStreamKey:
      "Select a Landscape Stream Key before starting YouTube output."
    case .missingPortraitStreamKey:
      "Select a Portrait Stream Key before starting YouTube output."
    case .unsupportedIngestMode:
      "The selected YouTube ingest mode is not available for Version 4 Workspaces yet."
    }
  }
}

public enum WorkspaceV4YouTubeRTMPSDestinationResolver {
  public static func resolve(
    output: Ldtx_Workspace_V4_OutputConfiguration,
    configurations: [YouTubeRTMPSStreamKeyConfiguration],
    landscapeStreamID: String?,
    portraitStreamID: String?
  ) throws -> YouTubeRTMPSDestinations {
    let landscape = configurations.first { $0.id == landscapeStreamID }
    let portrait = configurations.first { $0.id == portraitStreamID }
    switch output.resolvedYouTubeIngestMode {
    case .landscapeRtmps:
      guard let landscape else { throw WorkspaceV4YouTubeOutputError.missingLandscapeStreamKey }
      return try YouTubeRTMPSDestinations(landscape: landscape.destination())
    case .portraitRtmps:
      guard let portrait else { throw WorkspaceV4YouTubeOutputError.missingPortraitStreamKey }
      return try YouTubeRTMPSDestinations(portrait: portrait.destination())
    case .dualRtmps:
      guard let landscape else { throw WorkspaceV4YouTubeOutputError.missingLandscapeStreamKey }
      guard let portrait else { throw WorkspaceV4YouTubeOutputError.missingPortraitStreamKey }
      return try YouTubeRTMPSDestinations(
        landscape: landscape.destination(), portrait: portrait.destination())
    default:
      throw WorkspaceV4YouTubeOutputError.unsupportedIngestMode
    }
  }
}
