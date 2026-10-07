// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct WorkspaceBundleInfoV4: Codable {
  var packageType = "BNDL"
  var workspaceVersion = 4
  var workspaceBundleVersion = "4.0"

  init() {}

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    packageType = try container.decode(String.self, forKey: .packageType)
    workspaceVersion = try container.decode(Int.self, forKey: .workspaceVersion)
    workspaceBundleVersion =
      (try? container.decode(String.self, forKey: .workspaceBundleVersion)) ?? "4.0"
  }

  enum CodingKeys: String, CodingKey {
    case packageType = "CFBundlePackageType"
    case workspaceVersion = "LDTXWorkspaceVersion"
    case workspaceBundleVersion = "LDTXWorkspaceBundleVersion"
  }
}
