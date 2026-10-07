// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos

public enum WorkspaceBundleReader {
  case v4(WorkspaceBundleReaderV4)
  case failure
}

public func makeWorkspaceBundleReader(at bundleURL: URL) -> WorkspaceBundleReader {
  struct AbstractWorkspaceBundleInfo: Decodable {
    let workspaceVersion: Int

    enum CodingKeys: String, CodingKey {
      case workspaceVersion = "LDTXWorkspaceVersion"
    }
  }

  let infoURL = bundleURL.appending(path: "Info.plist", directoryHint: .notDirectory)
  guard
    let infoData = try? Data(contentsOf: infoURL),
    let info = try? PropertyListDecoder().decode(
      AbstractWorkspaceBundleInfo.self, from: infoData)
  else {
    return .failure
  }

  switch info.workspaceVersion {
  case 4:
    return .v4(WorkspaceBundleReaderV4(at: bundleURL))
  default:
    return .failure
  }
}
