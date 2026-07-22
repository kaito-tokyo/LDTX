// SPDX-FileCopyrightText: 2026 Kaito Udagawa
//
// SPDX-License-Identifier: Apache-2.0

/// A value store whose revision identifies the complete store state.
protocol RevisionedStore {
  var revision: UInt64 { get set }
}

extension RevisionedStore {
  mutating func advanceRevision() {
    revision &+= 1
  }
}
