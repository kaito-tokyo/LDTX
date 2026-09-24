// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum WorkspaceAppletResources {
  private final class BundleToken {}

  public static let bundle = Bundle(for: BundleToken.self)
}
