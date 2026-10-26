// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct CameraCaptureSource: Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var deviceType: String
  public var modelID: String
  public var width: Int
  public var height: Int
  public var isExternal: Bool
  public var formatSummary: String

  public init(
    id: String,
    name: String,
    deviceType: String,
    modelID: String,
    width: Int,
    height: Int,
    isExternal: Bool,
    formatSummary: String
  ) {
    self.id = id
    self.name = name
    self.deviceType = deviceType
    self.modelID = modelID
    self.width = width
    self.height = height
    self.isExternal = isExternal
    self.formatSummary = formatSummary
  }
}
