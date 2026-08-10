// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

public struct InputPhysicalDeviceOption: Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var isExternal: Bool

  public init(id: String, name: String, isExternal: Bool) {
    self.id = id
    self.name = name
    self.isExternal = isExternal
  }
}
