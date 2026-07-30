// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXMP4
import LDTXOutputMedia
import LDTXProgram

public enum ProgramOutputEncodingConfiguration {
  public static func make(
    configuration: ProgramRuntimeConfiguration,
    startNumber: Int = 1
  ) -> SegmentedMP4WriterConfiguration {
    configuration.outputProfile.makeSegmentedMP4Configuration(startNumber: startNumber)
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
    var programAudio: @Sendable (ProgramOutputAACPacket) -> Void
    var outputWillStop: @Sendable () -> Void
  }

  private let lock = NSLock()
  private let outputProfile: ProgramOutputProfile
  private var handlersByID: [UUID: Handlers] = [:]
  private var programAACEncoder: AACAudioEncoder?
  private var failureHandler: (@Sendable (Error) -> Void)?

  public init(outputProfile: ProgramOutputProfile = .sdr1080p60) {
    self.outputProfile = outputProfile
  }

  public func subscribe(
    mainVideo: @escaping @Sendable (CMSampleBuffer) -> Void,
    programAudio: @escaping @Sendable (ProgramOutputAACPacket) -> Void,
    outputWillStop: @escaping @Sendable () -> Void = {}
  ) -> Subscription {
    let id = UUID()
    lock.withLock {
      handlersByID[id] = Handlers(
        video: mainVideo, programAudio: programAudio, outputWillStop: outputWillStop)
    }
    return Subscription(id: id)
  }

  public func unsubscribe(_ subscription: Subscription) {
    _ = lock.withLock { handlersByID.removeValue(forKey: subscription.id) }
  }

  /// Encoding is shared, so an AAC failure invalidates every consumer of the
  /// output contract.  Report it to the owning Output Session rather than
  /// silently dropping Program audio for recording and streaming alike.
  func setFailureHandler(_ handler: (@Sendable (Error) -> Void)?) {
    lock.withLock { failureHandler = handler }
  }

  func publishMainVideo(_ sampleBuffer: CMSampleBuffer) {
    let handlers = lock.withLock { Array(handlersByID.values) }
    for handler in handlers { handler.video(sampleBuffer) }
  }

  func publishMainAudioMix(_ sampleBuffer: CMSampleBuffer) {
    let encoded: [CMSampleBuffer]
    let handlers: [Handlers]
    do {
      (encoded, handlers) = try lock.withLock {
        if programAACEncoder == nil {
          guard let format = sampleBuffer.formatDescription else {
            throw AACAudioEncoderError.invalidFormat
          }
          programAACEncoder = try AACAudioEncoder(
            inputFormatDescription: format,
            bitRate: outputProfile.audioBitRate,
            outputSampleRate: Double(outputProfile.audioSampleRate),
            outputChannelCount: outputProfile.audioChannelCount)
        }
        return (try programAACEncoder?.encode(sampleBuffer) ?? [], Array(handlersByID.values))
      }
    } catch {
      let failureHandler = lock.withLock { self.failureHandler }
      failureHandler?(error)
      return
    }
    for sample in encoded {
      do {
        let packet = try makeProgramAudioPacket(from: sample)
        for handler in handlers { handler.programAudio(packet) }
      } catch {
        let failureHandler = lock.withLock { self.failureHandler }
        failureHandler?(error)
        return
      }
    }
  }

  func publishOutputWillStop() {
    let result: Result<([CMSampleBuffer], [Handlers]), Error> = lock.withLock {
      do {
        let finalAudio = try programAACEncoder?.finish() ?? []
        programAACEncoder = nil
        return .success((finalAudio, Array(handlersByID.values)))
      } catch {
        programAACEncoder = nil
        return .failure(error)
      }
    }
    let (finalAudio, handlers): ([CMSampleBuffer], [Handlers])
    switch result {
    case .success(let value): (finalAudio, handlers) = value
    case .failure(let error):
      let failureHandler = lock.withLock { self.failureHandler }
      failureHandler?(error)
      (finalAudio, handlers) = ([], lock.withLock { Array(handlersByID.values) })
    }
    for sample in finalAudio {
      do {
        let packet = try makeProgramAudioPacket(from: sample)
        for handler in handlers { handler.programAudio(packet) }
      } catch {
        let failureHandler = lock.withLock { self.failureHandler }
        failureHandler?(error)
        break
      }
    }
    for handler in handlers { handler.outputWillStop() }
  }

  private func makeProgramAudioPacket(from sample: CMSampleBuffer) throws -> ProgramOutputAACPacket {
    let format = try ProgramOutputMediaSampleConverter.aacFormat(from: sample)
    guard format.sampleRate == Double(outputProfile.audioSampleRate),
      format.channelCount == Int32(outputProfile.audioChannelCount)
    else { throw ProgramOutputMediaHubError.unexpectedEncodedAudioFormat }
    return ProgramOutputAACPacket(
      format: format,
      accessUnit: try ProgramOutputMediaSampleConverter.aacAccessUnit(from: sample))
  }
}

private enum ProgramOutputMediaHubError: LocalizedError {
  case unexpectedEncodedAudioFormat

  var errorDescription: String? {
    "The shared Program AAC encoder did not produce the selected output audio format."
  }
}
