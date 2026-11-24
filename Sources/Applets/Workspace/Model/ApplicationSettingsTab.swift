// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

/// The tabs of the application's Settings scene.
///
/// The selected tab is an application preference stored under ``defaultsKey``,
/// so a Workspace window can choose the tab before opening Settings.
public enum ApplicationSettingsTab: String, CaseIterable, Sendable {
  case account
  case audio
  case output
  case streamKeys

  public static let defaultsKey = "tokyo.kaito.ldtx.Settings.selectedTab"
}
