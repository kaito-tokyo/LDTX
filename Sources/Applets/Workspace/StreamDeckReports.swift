// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

/// Stream Deck MK.2 input report state.
struct StreamDeckPressState {
  private var previous = [Bool](repeating: false, count: 15)
  private var startPauseArmed = false

  private static func decode(_ bytes: [UInt8]) -> [Bool]? {
    guard bytes.count >= 19,
      bytes[0] == 0x01, bytes[1] == 0x00, bytes[2] == 15, bytes[3] == 0,
      bytes[4..<19].allSatisfy({ $0 == 0 || $0 == 1 })
    else { return nil }
    return (0..<15).map { bytes[$0 + 4] == 1 }
  }

  mutating func seed(_ bytes: [UInt8]) {
    guard let pressed = Self.decode(bytes) else { return }
    previous = pressed
    startPauseArmed = false
  }

  mutating func receive(_ bytes: [UInt8]) -> [Int] {
    guard let pressed = Self.decode(bytes) else { return [] }
    defer { previous = pressed }
    var edges: [Int] = []
    for key in 0..<3 {
      if key == 1 {
        if pressed[key] && !previous[key] { startPauseArmed = true }
        if !pressed[key] && previous[key] {
          if startPauseArmed { edges.append(key) }
          startPauseArmed = false
        }
        continue
      }
      if pressed[key] && !previous[key] { edges.append(key) }
    }
    return edges
  }
}

struct StreamDeckImageReport {
  static func make(image: [UInt8], key: Int, offset: Int) -> [UInt8] {
    let size = min(1016, image.count - offset)
    let page = offset / 1016
    var bytes = [UInt8](repeating: 0, count: 1024)
    bytes[0] = 0x02
    bytes[1] = 0x07
    bytes[2] = UInt8(key)
    bytes[3] = offset + size == image.count ? 1 : 0
    bytes[4] = UInt8(size & 255)
    bytes[5] = UInt8(size >> 8)
    bytes[6] = UInt8(page & 255)
    bytes[7] = UInt8(page >> 8)
    bytes.replaceSubrange(8..<(8 + size), with: image[offset..<(offset + size)])
    return bytes
  }
}
