// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

// Production Info.plist IO is an exception to Codable property-list IO:
// user-defined keys and values must remain intact. Tests may use Encoder/Decoder
// models for their known fixtures and assertions.
struct WorkspaceBundleInfoV4 {
  var values: [String: Any] = [
    "CFBundlePackageType": "BNDL",
    "LDTXWorkspaceVersion": 4,
    "LDTXWorkspaceBundleVersion": "4.0",
  ]

  var packageType: String? { values["CFBundlePackageType"] as? String }
  var workspaceVersion: Int? { values["LDTXWorkspaceVersion"] as? Int }
  var workspaceBundleVersion: String { values["LDTXWorkspaceBundleVersion"] as? String ?? "4.0" }

  init() {}

  init(data: Data) throws {
    guard
      let values = try PropertyListSerialization.propertyList(
        from: data, options: .init(), format: nil) as? [String: Any]
    else { throw CocoaError(.fileReadCorruptFile) }
    self.values = values
  }

  func encodedData() throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
  }
}
