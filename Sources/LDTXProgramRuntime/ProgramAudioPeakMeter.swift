// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import Foundation
import LDTXProgram

public final class ProgramAudioPeakMeter: @unchecked Sendable {
  public enum Master: Int, CaseIterable, Sendable { case landscape, portrait }
  private let lock = NSRecursiveLock()
  private var engine: WorkspaceAudioEngine?
  private var channels: [ProgramAudioChannel] = []
  private var mappings: [String: String] = [:]
  private var preferences = [ProgramPreferences(), ProgramPreferences()]
  private let owners = [UUID(), UUID()]
  private var buses: [UInt64] = []
  private var peakCache: [String: (UInt64, Float)] = [:]
  private var inputIDs: [String: UInt64] = [:]
  public init() {}
  public func updateMasterGains(
    channels: [ProgramAudioChannel], landscape: ProgramPreferences, portrait: ProgramPreferences
  ) {
    lock.withLock {
      self.channels = channels
      preferences = [landscape, portrait]
      configure()
    }
  }
  func bind(
    engine: WorkspaceAudioEngine, channels: [ProgramAudioChannel], mappings: [String: String]
  ) {
    lock.withLock {
      self.engine = engine
      self.channels = channels
      self.mappings = mappings
      configure()
    }
  }
  private func configure() {
    guard let engine else { return }
    buses = preferences.enumerated().map { index, preference in
      engine.configureBus(
        owner: owners[index],
        routes: engine.routes(channels: channels, mappings: mappings, preferences: preference),
        master: Float(preference.masterVolume))
    }
    inputIDs = Dictionary(
      uniqueKeysWithValues: channels.compactMap { channel in
        let key = channels.audioChannelKey(for: channel)
        guard case .inputAudioDevice = channel.component.definition,
          let uid = mappings[channels.inputAudioDeviceMappingKey(for: channel)]
        else { return nil }
        return (key, engine.input(uid: uid))
      })
  }
  public func peak(for master: Master) -> Float {
    lock.withLock {
      guard let engine, buses.indices.contains(master.rawValue) else { return 0 }
      // A shared bus has two UI readers; cache one observation per display tick.
      return cachedPeak(engine: engine, source: buses[master.rawValue], raw: false)
    }
  }
  public func peak(for channelKey: String) -> Float {
    lock.withLock {
      guard let engine, let input = inputIDs[channelKey] else { return 0 }
      return cachedPeak(engine: engine, source: input, raw: true)
    }
  }
  private func cachedPeak(engine: WorkspaceAudioEngine, source: UInt64, raw: Bool) -> Float {
    let tick = DispatchTime.now().uptimeNanoseconds / 33_333_333
    let key = "\(raw):\(source)"
    if let (previous, value) = peakCache[key], previous == tick { return value }
    let value = engine.peak(source: source, raw: raw)
    peakCache[key] = (tick, value)
    return value
  }
  public func reset() {
    lock.withLock {
      if let engine { for owner in owners { engine.releaseBus(owner: owner) } }
      engine = nil
      buses = []
      inputIDs = [:]
      peakCache = [:]
    }
  }
}
