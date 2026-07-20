// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

public struct WorkspaceFeatureAvailability: Equatable, Sendable {
  public var supportsBackgroundRemoval: Bool
  public var supportsVision: Bool
  public var supportsAutomation: Bool
  public var supportsYouTube: Bool

  public static let all = WorkspaceFeatureAvailability(
    supportsBackgroundRemoval: true,
    supportsVision: true,
    supportsAutomation: true,
    supportsYouTube: true
  )

  /// Features available in an app target that omits AI implementations.
  public static let aiFree = WorkspaceFeatureAvailability(
    supportsBackgroundRemoval: false,
    supportsVision: false,
    supportsAutomation: false,
    supportsYouTube: true
  )

  public init(
    supportsBackgroundRemoval: Bool,
    supportsVision: Bool,
    supportsAutomation: Bool,
    supportsYouTube: Bool
  ) {
    self.supportsBackgroundRemoval = supportsBackgroundRemoval
    self.supportsVision = supportsVision
    self.supportsAutomation = supportsAutomation
    self.supportsYouTube = supportsYouTube
  }
}
