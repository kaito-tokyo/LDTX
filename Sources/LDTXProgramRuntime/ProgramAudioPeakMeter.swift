// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAudioEngine
import LDTXProgram
import LDTXMP4

public final class ProgramAudioPeakMeter: @unchecked Sendable {
  private let lock = NSLock()
  private var audioEngine: LDTXAudioMixEngine?
  private var channelIndicesByKey: [String: Int32] = [:]

  public enum Master: Int, CaseIterable, Sendable {
    case landscape, portrait
  }

  private var masterGains: [String: [Float]] = [:]
  private var masterPeaks = [Float](repeating: 0, count: 2)

  public init() {}

  public func updateMasterGains(
    channels: [ProgramAudioChannel], landscape: ProgramPreferences,
    portrait: ProgramPreferences
  ) {
    let gains = Dictionary(uniqueKeysWithValues: channels.map { channel in
      let key = channels.audioChannelKey(for: channel)
      return (key, [
        Float(landscape.outputAudioChannelGain(for: channel, in: channels)),
        Float(portrait.outputAudioChannelGain(for: channel, in: channels)),
      ])
    })
    lock.withLock { masterGains = gains }
  }

  public func peak(for master: Master) -> Float {
    lock.withLock {
      let value = masterPeaks[master.rawValue]
      masterPeaks[master.rawValue] = 0
      return value
    }
  }

  // Use aligned PCM samples, not the sum of source peaks: opposite phases
  // must cancel before measuring the output peak.
  struct MasterBlock {
    var engines: [LDTXAudioMixEngine]
    let indices: [String: Int32]
    var samples: [[Float]]

    mutating func add(_ source: [Float], channelKey: String) {
      guard let channelIndex = indices[channelKey] else { return }
      for bus in Master.allCases {
        source.withUnsafeBufferPointer { input in
          samples[bus.rawValue].withUnsafeMutableBufferPointer { output in
            engines[bus.rawValue].mixInterleavedFloat32(
              channelIndex, input.baseAddress, output.baseAddress,
              Int32(source.count / AudioSampleBufferNormalizer.channelCount),
              Int32(AudioSampleBufferNormalizer.channelCount), false)
          }
        }
      }
    }
  }

  func beginMasterBlock(
    sampleCount: Int, engines: [LDTXAudioMixEngine], channelKeys: [String]
  ) -> MasterBlock {
    let gains = lock.withLock { masterGains }
    var engines = engines
    for (index, key) in channelKeys.enumerated() {
      for bus in Master.allCases {
        engines[bus.rawValue].setChannelGain(Int32(index), gains[key]?[bus.rawValue] ?? 0)
      }
    }
    return MasterBlock(
      engines: engines,
      indices: Dictionary(uniqueKeysWithValues: channelKeys.enumerated().map { ($0.element, Int32($0.offset)) }),
      samples: Array(repeating: Array(repeating: 0, count: sampleCount), count: 2))
  }

  func finishMasterBlock(_ block: MasterBlock) {
    let peaks = block.samples.map { samples in samples.reduce(Float(0)) { max($0, abs($1)) } }
    lock.withLock {
      for index in peaks.indices { masterPeaks[index] = max(masterPeaks[index], peaks[index]) }
    }
  }

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
    masterPeaks = [Float](repeating: 0, count: 2)
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
