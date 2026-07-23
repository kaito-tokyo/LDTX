// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXMP4
import LDTXProgram

public enum ProgramOutputEncodingConfiguration {
  public static func make(
    configuration: ProgramRuntimeConfiguration,
    startNumber: Int = 1
  ) -> SegmentedMP4WriterConfiguration {
    let frameRate = max(configuration.frameRate, 1)
    let bitRate: Int
    if configuration.outputWidth >= 1_920 || configuration.outputHeight >= 1_080 {
      bitRate = frameRate >= 60 ? 6_000_000 : 4_500_000
    } else {
      bitRate = frameRate >= 60 ? 4_000_000 : 2_500_000
    }
    return SegmentedMP4WriterConfiguration(
      width: configuration.outputWidth,
      height: configuration.outputHeight,
      frameRate: frameRate,
      videoBitRate: bitRate,
      startNumber: startNumber
    )
  }
}

/// The Workspace-owned connection point between an Output Session and output
/// services. The session only publishes its two products; it does not know
/// which services consume them.
public final class ProgramOutputMediaHub: @unchecked Sendable {
  public struct Subscription: Hashable, Sendable {
    fileprivate let id: UUID
  }

  private struct Handlers {
    var video: @Sendable (CMSampleBuffer) -> Void
    var audioMix: @Sendable (CMSampleBuffer) -> Void
    var outputWillStop: @Sendable () -> Void
  }

  private let lock = NSLock()
  private var handlersByID: [UUID: Handlers] = [:]

  public init() {}

  public func subscribe(
    mainVideo: @escaping @Sendable (CMSampleBuffer) -> Void,
    mainAudioMix: @escaping @Sendable (CMSampleBuffer) -> Void,
    outputWillStop: @escaping @Sendable () -> Void = {}
  ) -> Subscription {
    let id = UUID()
    lock.withLock {
      handlersByID[id] = Handlers(
        video: mainVideo, audioMix: mainAudioMix, outputWillStop: outputWillStop)
    }
    return Subscription(id: id)
  }

  public func unsubscribe(_ subscription: Subscription) {
    _ = lock.withLock { handlersByID.removeValue(forKey: subscription.id) }
  }

  func publishMainVideo(_ sampleBuffer: CMSampleBuffer) {
    let handlers = lock.withLock { Array(handlersByID.values) }
    for handler in handlers { handler.video(sampleBuffer) }
  }

  func publishMainAudioMix(_ sampleBuffer: CMSampleBuffer) {
    let handlers = lock.withLock { Array(handlersByID.values) }
    for handler in handlers { handler.audioMix(sampleBuffer) }
  }

  func publishOutputWillStop() {
    let handlers = lock.withLock { Array(handlersByID.values) }
    for handler in handlers { handler.outputWillStop() }
  }
}
