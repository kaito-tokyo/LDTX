// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Validates the V4 Workspace bundle's on-disk metadata.
public struct WorkspaceBundleValidatorV4 {
  public let bundleURL: URL

  public init(at bundleURL: URL) {
    self.bundleURL = bundleURL
  }

  var infoURL: URL {
    bundleURL.appending(path: "Info.plist", directoryHint: .notDirectory)
  }

  public func validate() throws -> String {
    let infoData = try Data(contentsOf: infoURL)
    guard
      let info = try? PropertyListDecoder().decode(WorkspaceBundleInfoV4.self, from: infoData),
      info.packageType == "BNDL",
      info.workspaceVersion == 4
    else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: infoURL])
    }

    return info.workspaceBundleVersion
  }
}
