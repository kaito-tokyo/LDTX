// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

extension Ldtx_Workspace_V4_YouTubeIngestMode {
  public var usesLandscapeRTMPS: Bool {
    switch self {
    case .unspecified, .landscapeRtmps, .dualRtmps: true
    case .portraitRtmps, .landscapeHls, .portraitHls,
      .landscapeDash, .portraitDash, .UNRECOGNIZED:
      false
    }
  }

  public var usesPortraitRTMPS: Bool {
    switch self {
    case .portraitRtmps, .dualRtmps: true
    case .unspecified, .landscapeRtmps, .landscapeHls, .portraitHls,
      .landscapeDash, .portraitDash, .UNRECOGNIZED:
      false
    }
  }
}
