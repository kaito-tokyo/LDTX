// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos

@MainActor
public final class WorkspaceInternalIDGenerator {
  private let clock: () -> Date
  private let randomSuffix: () -> Int64
  private let sleep: (TimeInterval) -> Void
  private var issuedIDs: Set<Int64> = []

  public convenience init() {
    self.init(
      clock: Date.init, randomSuffix: { Int64.random(in: 0...0x3fff) },
      sleep: { Thread.sleep(forTimeInterval: $0) })
  }

  init(
    clock: @escaping () -> Date, randomSuffix: @escaping () -> Int64,
    sleep: @escaping (TimeInterval) -> Void
  ) {
    self.clock = clock
    self.randomSuffix = randomSuffix
    self.sleep = sleep
  }

  public func next(existingIDs: Set<Int64> = []) -> Int64 {
    while true {
      let milliseconds = Int64(max(0, clock().timeIntervalSince1970 * 1_000))
      let timestamp = (milliseconds & 0x0000_FFFF_FFFF_FFFF) << 15
      let id = timestamp | ((randomSuffix() & 0x3fff) << 1) | 1
      if !existingIDs.contains(id), issuedIDs.insert(id).inserted {
        return id
      }
      // Intentionally block MainActor for 1 ms before generating another candidate.
      sleep(0.001)
    }
  }

  public func next(
    in definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4, additionalIDs: Set<Int64> = []
  ) -> Int64 {
    let ids = Set(definition.audioDevices.map(\.internalID))
      .union(definition.videoComponents.compactMap(\.internalID))
      .union(definition.programs.map(\.internalID))
      .union(definition.visions.compactMap(\.internalID))
      .union(additionalIDs)
    return next(existingIDs: ids)
  }
}
