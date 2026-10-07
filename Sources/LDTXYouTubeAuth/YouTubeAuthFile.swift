// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

#if !LDTX_DISTRIBUTION
  final class YouTubeAuthFile {
    struct Contents: Codable {
      var oauthClientJSON: Data?
      var authorizations: [String: Data] = [:]

      init() {}

      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        oauthClientJSON = try container.decodeIfPresent(Data.self, forKey: .oauthClientJSON)
        authorizations =
          try container.decodeIfPresent(
            [String: Data].self, forKey: .authorizations) ?? [:]
      }
    }

    let url: URL

    init(url: URL) { self.url = url }

    func read() throws -> Contents {
      let data = try Data(contentsOf: url)
      if data.isEmpty { return Contents() }
      return try JSONDecoder().decode(Contents.self, from: data)
    }

    func update(_ change: (inout Contents) -> Void) throws {
      var contents = try read()
      change(&contents)
      let data = try JSONEncoder().encode(contents)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
  }
#endif
