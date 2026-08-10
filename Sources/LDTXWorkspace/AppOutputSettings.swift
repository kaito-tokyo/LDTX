// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct AppPreviewSettings: Equatable, Sendable {
  public var prefersColor: Bool

  public init(prefersColor: Bool = false) {
    self.prefersColor = prefersColor
  }
}

public enum AppPreviewSettingsPersistenceCodec {
  public static func encode(_ settings: AppPreviewSettings) throws -> Data {
    var proto = Ldtx_App_V1_PreviewSettings()
    proto.prefersColor = settings.prefersColor
    return try proto.serializedData()
  }

  public static func decode(from data: Data) throws -> AppPreviewSettings {
    let proto = try Ldtx_App_V1_PreviewSettings(serializedBytes: data)
    return AppPreviewSettings(prefersColor: proto.prefersColor)
  }
}
