// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum CameraInputColorRangeOverride: String, Codable, Equatable, Sendable {
  case unspecified
  case videoRange
  case fullRange
}
