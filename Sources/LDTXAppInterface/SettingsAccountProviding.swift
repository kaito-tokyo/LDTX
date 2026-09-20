// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Combine

@MainActor
public protocol SettingsAccountProviding: ObservableObject {
  var oauthStatus: String { get }
  var authorizationStatus: String { get }
  var isImportingOAuthClient: Bool { get set }
  var canAuthorize: Bool { get }

  func restoreAuthorization()
  func authorizeYouTube()
  @discardableResult func loadOAuthClient(from url: URL) -> Bool
}
