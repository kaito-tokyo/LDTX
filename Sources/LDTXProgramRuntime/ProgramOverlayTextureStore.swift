// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXVideoComposition

/// The compositor reads immutable completed textures. Only the independent producer publishes.
public final class ProgramOverlayTextureStore: @unchecked Sendable {
  private struct Entry {
    var generation: UUID
    var destination: SIMD4<UInt32>
    var source: SIMD4<Float>
    var texture: ClockOverlayTexture?
  }
  private let lock = NSLock()
  private var entries: [String: Entry] = [:]

  public init() {}

  public func snapshot() -> [String: RetainedTextureComponent] {
    lock.withLock {
      entries.compactMapValues { entry in
        guard let texture = entry.texture else { return nil }
        return RetainedTextureComponent(
          colorTexture: texture.colorTexture, alphaTexture: texture.alphaTexture,
          destinationRect: entry.destination, sourceRect: entry.source)
      }
    }
  }

  func place(_ name: String, generation: UUID, destination: SIMD4<UInt32>, source: SIMD4<Float>) {
    lock.withLock {
      let texture = entries[name].flatMap { $0.generation == generation ? $0.texture : nil }
      entries[name] = Entry(
        generation: generation, destination: destination, source: source, texture: texture)
    }
  }

  func publish(_ texture: ClockOverlayTexture, name: String, generation: UUID) {
    lock.withLock {
      guard entries[name]?.generation == generation else { return }
      entries[name]?.texture = texture
    }
  }

  func retain(_ names: Set<String>) {
    lock.withLock { entries = entries.filter { names.contains($0.key) } }
  }
}
