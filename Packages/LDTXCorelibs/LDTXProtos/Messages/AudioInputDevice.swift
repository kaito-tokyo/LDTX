// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct AudioInputDevice: Identifiable, Equatable, Sendable {
  public let uid: String
  public let name: String
  public let inputChannelCount: Int

  public var id: String { uid }

  public init(uid: String, name: String, inputChannelCount: Int) {
    self.uid = uid
    self.name = name
    self.inputChannelCount = inputChannelCount
  }
}
