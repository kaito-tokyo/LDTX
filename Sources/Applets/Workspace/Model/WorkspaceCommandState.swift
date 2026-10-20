// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

/// Requested state identity includes a sequence number so an explicit reapply
/// after a Stall can differ from an otherwise identical value. No independent
/// dirty flag or timestamp participates. The Workspace's command queue advances
/// retryNumber once when it confirms Stall, not when an apply request is made.
public struct WorkspaceCommandState<Value: Equatable & Sendable>: Equatable, Sendable {
  public let value: Value
  public let retryNumber: UInt64

  public init(value: Value, retryNumber: UInt64) {
    self.value = value
    self.retryNumber = retryNumber
  }
}
