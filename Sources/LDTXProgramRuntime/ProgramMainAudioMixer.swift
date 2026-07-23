// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXCapture
import LDTXProgram

protocol ProgramMainAudioMixing: AnyObject, Sendable {
  func start(
    audioChannels: [ProgramAudioChannel],
    inputAudioDeviceMappings: [String: String],
    programPreferences: ProgramPreferences,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  )
  func addMainAudioMixHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) -> UUID
  func removeMainAudioMixHandler(id: UUID)
  func updateGains(audioChannels: [ProgramAudioChannel], programPreferences: ProgramPreferences)
  func noteVideoPresentationTime(_ presentationTime: CMTime)
  func stop(completionHandler: @escaping @Sendable () -> Void)
}

/// Output-only audio producer. It deliberately exposes neither monitoring nor
/// per-input recording taps even though it shares the low-level mixer engine.
final class ProgramMainAudioMixer: ProgramMainAudioMixing, @unchecked Sendable {
  private let engine = ProgramAudioMixPipeline()
  private let inputCaptureController = ProgramAudioInputCaptureController()

  func start(
    audioChannels: [ProgramAudioChannel],
    inputAudioDeviceMappings: [String: String],
    programPreferences: ProgramPreferences,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    engine.restart(
      audioChannels: audioChannels,
      inputAudioDeviceMappings: inputAudioDeviceMappings,
      programPreferences: programPreferences,
      inputPassthroughChannelKeys: [],
      peakMeter: nil,
      completionHandler: { [self] result in
        guard case .success = result else {
          completionHandler(result)
          return
        }
        inputCaptureController.restart(
          audioChannels: audioChannels,
          inputAudioDeviceMappings: inputAudioDeviceMappings,
          failureHandler: failureHandler,
          sampleHandler: { [engine] channelKey, sampleBuffer, kind in
            engine.receiveInputSample(sampleBuffer, kind: kind, channelKey: channelKey)
          },
          completionHandler: { [self] result in
            if case .failure = result {
              engine.stop { completionHandler(result) }
            } else {
              completionHandler(result)
            }
          })
      })
  }

  func addMainAudioMixHandler(
    _ handler: @escaping @Sendable (CMSampleBuffer) -> Void
  ) -> UUID {
    engine.addOutputSampleHandler(handler)
  }

  func removeMainAudioMixHandler(id: UUID) { engine.removeOutputSampleHandler(id: id) }
  func updateGains(
    audioChannels: [ProgramAudioChannel],
    programPreferences: ProgramPreferences
  ) {
    engine.updateGains(audioChannels: audioChannels, preferences: programPreferences)
  }
  func noteVideoPresentationTime(_ presentationTime: CMTime) {
    engine.noteVideoPresentationTime(presentationTime)
  }
  func stop(completionHandler: @escaping @Sendable () -> Void) {
    inputCaptureController.stop { [engine] in
      engine.stop(completionHandler: completionHandler)
    }
  }
}
