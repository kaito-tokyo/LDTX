// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAudioEngine

public final class ProgramAudioPeakMeter: @unchecked Sendable {
  private let lock = NSLock()
  private var audioEngine: LDTXAudioMixEngine?
  private var channelIndicesByKey: [String: Int32] = [:]

  public init() {}

  func bind(audioEngine: LDTXAudioMixEngine, channelKeys: [String]) {
    lock.lock()
    defer { lock.unlock() }
    self.audioEngine = audioEngine
    channelIndicesByKey = Dictionary(
      uniqueKeysWithValues: channelKeys.enumerated().map { index, key in
        (key, Int32(index))
      }
    )
  }

  public func reset() {
    lock.lock()
    defer { lock.unlock() }
    audioEngine = nil
    channelIndicesByKey = [:]
  }

  public func peak(for channelKey: String) -> Float {
    lock.lock()
    defer { lock.unlock() }
    guard var audioEngine,
      let channelIndex = channelIndicesByKey[channelKey]
    else {
      return 0
    }
    let peak = audioEngine.consumeChannelPeak(channelIndex)
    self.audioEngine = audioEngine
    return peak
  }
}
