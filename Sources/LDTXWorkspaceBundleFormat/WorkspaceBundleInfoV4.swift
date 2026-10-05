// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct WorkspaceBundleInfoV4: Codable {
  var packageType = "BNDL"
  var workspaceVersion = 4
  var workspaceBundleVersion = "4.1"

  enum CodingKeys: String, CodingKey {
    case packageType = "CFBundlePackageType"
    case workspaceVersion = "LDTXWorkspaceVersion"
    case workspaceBundleVersion = "LDTXWorkspaceBundleVersion"
  }
}
