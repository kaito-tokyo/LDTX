// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import Foundation
import LDTXAudioEngine
import LDTXCapture
import LDTXMP4
import LDTXMediaTiming
import LDTXProgram
import OSLog

private let programAudioMonitorLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "ProgramAudioMonitor"
)

/// Workspace-facing monitor. Its lifetime owns only monitoring behavior; the
/// reusable capture/mix pipeline is also used independently by Output Session.
public final class ProgramAudioMonitor: @unchecked Sendable {
  private let pipeline: ProgramAudioMixPipeline

  public init(
    scheduler: any ProgramRuntimeScheduling = SystemProgramRuntimeScheduler()
  ) {
    pipeline = ProgramAudioMixPipeline(scheduler: scheduler)
  }

  public func restart(
    audioChannels: [ProgramAudioChannel],
    inputAudioDeviceMappings: [String: String],
    programPreferences: ProgramPreferences,
    inputPassthroughChannelKeys: Set<String>,
    peakMeter: ProgramAudioPeakMeter,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    pipeline.restart(
      audioChannels: audioChannels,
      inputAudioDeviceMappings: inputAudioDeviceMappings,
      programPreferences: programPreferences,
      inputPassthroughChannelKeys: inputPassthroughChannelKeys,
      peakMeter: peakMeter,
      completionHandler: completionHandler)
  }

  public func receiveInputSample(
    _ sampleBuffer: CMSampleBuffer,
    kind: CameraCaptureSampleKind,
    channelKey: String
  ) {
    pipeline.receiveInputSample(sampleBuffer, kind: kind, channelKey: channelKey)
  }

  public func updateGains(
    audioChannels: [ProgramAudioChannel],
    preferences: ProgramPreferences
  ) {
    pipeline.updateGains(audioChannels: audioChannels, preferences: preferences)
  }

  public func stop(completionHandler: @escaping @Sendable () -> Void = {}) {
    pipeline.stop(completionHandler: completionHandler)
  }
}

/// Sample-consumer and mix implementation with no capture, UI, or Session
/// ownership. Every consumer creates its own timing and handler state.
final class ProgramAudioMixPipeline: @unchecked Sendable {
  private let lock = NSLock()
  private var audioEngine = LDTXAudioMixEngine(1)
  private var channelIndicesByKey: [String: Int32] = [:]
  private var inputSinksByChannelKey: [String: ProgramAudioMonitorSink] = [:]
  private var activeInputPassthroughChannelKeys: Set<String> = []
  private var generatedSources: [ProgramAudioMonitorGeneratedSource] = []
  private var outputDriver: ProgramAudioMonitorOutputDriver?
  private let output = ProgramAudioMonitorOutput()
  private let inputSamples = ProgramAudioMonitorInputSamples()
  private let timingAnchor = ProgramAudioMonitorTimingAnchor()
  private let inputPassthrough = ProgramAudioInputPassthrough()
  private let scheduler: any ProgramRuntimeScheduling

  init(
    scheduler: any ProgramRuntimeScheduling = SystemProgramRuntimeScheduler()
  ) {
    self.scheduler = scheduler
  }

  public func restart(
    audioChannels: [ProgramAudioChannel],
    inputAudioDeviceMappings: [String: String],
    programPreferences: ProgramPreferences,
    inputPassthroughChannelKeys: Set<String>,
    peakMeter: ProgramAudioPeakMeter?,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    let channelKeys = audioChannels.map { audioChannels.audioChannelKey(for: $0) }
    guard !channelKeys.isEmpty else {
      stop {
        peakMeter?.reset()
        completionHandler(.success(()))
      }
      return
    }

    var nextEngine = LDTXAudioMixEngine(Int32(channelKeys.count))
    let nextIndices = Dictionary(
      uniqueKeysWithValues: channelKeys.enumerated().map { index, key in
        (key, Int32(index))
      }
    )
    var gainsByChannelKey: [String: Float] = [:]
    for channel in audioChannels {
      let key = audioChannels.audioChannelKey(for: channel)
      guard let index = nextIndices[key] else {
        continue
      }
      let gain = Float(programPreferences.outputAudioChannelGain(for: channel, in: audioChannels))
      gainsByChannelKey[key] = gain
      nextEngine.setChannelGain(index, gain)
    }
    let mixer: ProgramAudioMonitorMixer
    do {
      mixer = try ProgramAudioMonitorMixer(
        audioEngine: nextEngine,
        channelCount: Int32(channelKeys.count),
        output: output
      )
    } catch {
      completionHandler(.failure(error))
      return
    }
    peakMeter?.bind(audioEngine: nextEngine, channelKeys: channelKeys)
    let activeInputPassthroughChannelKeys = Set(
      Self.inputPassthroughChannelKeys(
        audioChannels: audioChannels,
        inputAudioDeviceMappings: inputAudioDeviceMappings
      ).filter(inputPassthroughChannelKeys.contains)
    )
    inputPassthrough.configure(
      channelGainsByKey: Dictionary(
        uniqueKeysWithValues: activeInputPassthroughChannelKeys.map { key in
          (key, gainsByChannelKey[key] ?? 1)
        }
      ))

    var inputSinks: [String: ProgramAudioMonitorSink] = [:]
    var nextGeneratedSources: [ProgramAudioMonitorGeneratedSource] = []
    var expectedChannelIndices: Set<Int32> = []
    do {
      for channel in audioChannels {
        let key = audioChannels.audioChannelKey(for: channel)
        guard let channelIndex = nextIndices[key] else { continue }
        switch channel.component.definition {
        case .inputAudioDevice:
          let mappingKey = audioChannels.inputAudioDeviceMappingKey(for: channel)
          guard let deviceID = inputAudioDeviceMappings[mappingKey], !deviceID.isEmpty else {
            continue
          }
          inputSinks[key] = try ProgramAudioMonitorSink(
            channelIndex: channelIndex, mixer: mixer, timingAnchor: timingAnchor)
          expectedChannelIndices.insert(channelIndex)
        case .testPatternAudio:
          nextGeneratedSources.append(
            try ProgramAudioMonitorGeneratedSource(
              channelIndex: channelIndex,
              mixer: mixer,
              mode: .sweepSine,
              timingAnchor: timingAnchor))
          expectedChannelIndices.insert(channelIndex)
        case .silentAudio:
          nextGeneratedSources.append(
            try ProgramAudioMonitorGeneratedSource(
              channelIndex: channelIndex,
              mixer: mixer,
              mode: .silence,
              timingAnchor: timingAnchor))
          expectedChannelIndices.insert(channelIndex)
        }
      }
      let nextOutputDriver = try ProgramAudioMonitorOutputDriver(
        mixer: mixer,
        timingAnchor: timingAnchor,
        expectedChannelIndices: expectedChannelIndices,
        scheduler: scheduler)
      let previousSources = replaceState(
        audioEngine: nextEngine,
        channelIndicesByKey: nextIndices,
        inputSinksByChannelKey: inputSinks,
        activeInputPassthroughChannelKeys: activeInputPassthroughChannelKeys,
        generatedSources: nextGeneratedSources,
        outputDriver: nextOutputDriver)
      stop(sources: previousSources)
      for source in nextGeneratedSources { source.start() }
      nextOutputDriver.start()
      completionHandler(.success(()))
    } catch {
      for source in nextGeneratedSources { source.stop() }
      completionHandler(.failure(error))
    }
  }

  func receiveInputSample(
    _ sampleBuffer: CMSampleBuffer,
    kind: CameraCaptureSampleKind,
    channelKey: String
  ) {
    let state = lock.withLock {
      (
        sink: inputSinksByChannelKey[channelKey],
        passesThrough: activeInputPassthroughChannelKeys.contains(channelKey)
      )
    }
    guard let sink = state.sink else { return }
    if kind == .audio {
      inputSamples.append(sampleBuffer, forChannelKey: channelKey)
      if state.passesThrough { inputPassthrough.enqueue(sampleBuffer, for: channelKey) }
    }
    sink.append(sampleBuffer, kind: kind)
  }

  private static func inputPassthroughChannelKeys(
    audioChannels: [ProgramAudioChannel],
    inputAudioDeviceMappings: [String: String]
  ) -> [String] {
    audioChannels.compactMap { channel in
      guard case .inputAudioDevice = channel.component,
        let deviceID = inputAudioDeviceMappings[
          audioChannels.inputAudioDeviceMappingKey(for: channel)],
        !deviceID.isEmpty
      else {
        return nil
      }
      return audioChannels.audioChannelKey(for: channel)
    }
  }

  public func updateGains(
    audioChannels: [ProgramAudioChannel],
    preferences: ProgramPreferences
  ) {
    var engine: LDTXAudioMixEngine!
    let indices = lock.withLock {
      engine = audioEngine
      return channelIndicesByKey
    }

    var gainsByChannelKey: [String: Float] = [:]
    for channel in audioChannels {
      let key = audioChannels.audioChannelKey(for: channel)
      guard let channelIndex = indices[key] else {
        continue
      }
      let gain = Float(preferences.outputAudioChannelGain(for: channel, in: audioChannels))
      gainsByChannelKey[key] = gain
      engine.setChannelGain(channelIndex, gain)
    }
    inputPassthrough.updateGains(gainsByChannelKey)
  }

  @discardableResult
  func addOutputSampleHandler(
    _ handler: @escaping @Sendable (CMSampleBuffer) -> Void
  ) -> UUID {
    output.addSampleHandler(handler)
  }

  func removeOutputSampleHandler(id: UUID) {
    output.removeSampleHandler(id: id)
  }

  @discardableResult
  func addInputSampleHandler(
    forChannelKey channelKey: String,
    _ handler: @escaping @Sendable (CMSampleBuffer) -> Void
  ) -> UUID {
    inputSamples.addSampleHandler(forChannelKey: channelKey, handler)
  }

  func removeInputSampleHandler(id: UUID) {
    inputSamples.removeSampleHandler(id: id)
  }

  func noteVideoPresentationTime(_ presentationTime: CMTime) {
    timingAnchor.noteVideoPresentationTime(presentationTime)
  }

  public func stop(completionHandler: @escaping @Sendable () -> Void = {}) {
    timingAnchor.reset()
    output.resetTimeline()
    inputPassthrough.stop()
    let services = replaceState(
      audioEngine: LDTXAudioMixEngine(1),
      channelIndicesByKey: [:],
      inputSinksByChannelKey: [:],
      activeInputPassthroughChannelKeys: [],
      generatedSources: [],
      outputDriver: nil
    )
    stop(sources: services)
    completionHandler()
  }

  private func replaceState(
    audioEngine: LDTXAudioMixEngine,
    channelIndicesByKey: [String: Int32],
    inputSinksByChannelKey: [String: ProgramAudioMonitorSink],
    activeInputPassthroughChannelKeys: Set<String>,
    generatedSources: [ProgramAudioMonitorGeneratedSource],
    outputDriver: ProgramAudioMonitorOutputDriver?
  ) -> ProgramAudioMonitorRunningSources {
    lock.withLock {
      let previousSources = ProgramAudioMonitorRunningSources(
        generatedSources: self.generatedSources,
        outputDriver: self.outputDriver
      )
      self.audioEngine = audioEngine
      self.channelIndicesByKey = channelIndicesByKey
      self.inputSinksByChannelKey = inputSinksByChannelKey
      self.activeInputPassthroughChannelKeys = activeInputPassthroughChannelKeys
      self.generatedSources = generatedSources
      self.outputDriver = outputDriver
      return previousSources
    }
  }

  private func stop(
    sources: ProgramAudioMonitorRunningSources
  ) {
    sources.outputDriver?.stop()
    for source in sources.generatedSources {
      source.stop()
    }
  }
}

final class ProgramAudioMonitorInputSamples: @unchecked Sendable {
  private struct Handler {
    var channelKey: String
    var callback: @Sendable (CMSampleBuffer) -> Void
  }

  private let lock = NSLock()
  private var handlers: [UUID: Handler] = [:]

  func addSampleHandler(
    forChannelKey channelKey: String,
    _ handler: @escaping @Sendable (CMSampleBuffer) -> Void
  ) -> UUID {
    lock.withLock {
      let id = UUID()
      handlers[id] = Handler(channelKey: channelKey, callback: handler)
      return id
    }
  }

  func removeSampleHandler(id: UUID) {
    lock.withLock { handlers[id] = nil }
  }

  func append(_ sampleBuffer: CMSampleBuffer, forChannelKey channelKey: String) {
    let callbacks: [@Sendable (CMSampleBuffer) -> Void] = lock.withLock {
      return Array(
        handlers.values.lazy
          .filter { $0.channelKey == channelKey }
          .map(\.callback)
      )
    }
    for callback in callbacks {
      callback(sampleBuffer)
    }
  }
}

private struct ProgramAudioMonitorRunningSources {
  var generatedSources: [ProgramAudioMonitorGeneratedSource]
  var outputDriver: ProgramAudioMonitorOutputDriver?
}

final class ProgramAudioMonitorTimingAnchor: @unchecked Sendable {
  private let lock = NSLock()
  private var sessionVideoPresentationTime: CMTime?
  private var generation = 0

  func reset() {
    lock.withLock {
      sessionVideoPresentationTime = nil
      generation += 1
    }
  }

  func noteVideoPresentationTime(_ presentationTime: CMTime) {
    guard presentationTime.isNumeric else { return }
    lock.withLock {
      guard sessionVideoPresentationTime == nil else { return }
      sessionVideoPresentationTime = presentationTime
    }
  }

  func snapshot() -> (presentationTime: CMTime, generation: Int)? {
    lock.withLock {
      guard let sessionVideoPresentationTime else { return nil }
      return (sessionVideoPresentationTime, generation)
    }
  }
}

private final class ProgramAudioMonitorSink: @unchecked Sendable {
  private let lock = NSLock()
  private let channelIndex: Int32
  private let normalizer: AudioSampleBufferNormalizer
  private let mixer: ProgramAudioMonitorMixer
  private let timingAnchor: ProgramAudioMonitorTimingAnchor
  private var ptsClock: AudioFramePTSClock
  private var anchorGeneration: Int?

  init(
    channelIndex: Int32,
    mixer: ProgramAudioMonitorMixer,
    timingAnchor: ProgramAudioMonitorTimingAnchor
  ) throws {
    self.channelIndex = channelIndex
    self.mixer = mixer
    self.timingAnchor = timingAnchor
    normalizer = try AudioSampleBufferNormalizer()
    ptsClock = try AudioFramePTSClock(sampleRate: AudioSampleBufferNormalizer.sampleRate)
  }

  func append(_ sampleBuffer: CMSampleBuffer, kind: CameraCaptureSampleKind) {
    guard kind == .audio else { return }

    do {
      try normalizer.withNormalizedFloat32Samples(
        sampleBuffer,
        { [self] samples, frameCount in
          mixer.measurePeak(
            samples: samples,
            frameCount: frameCount,
            channelIndex: channelIndex
          )
          guard let presentationTime = nextPresentationTime(frameCount: frameCount) else {
            return
          }
          mixer.insert(
            samples: samples,
            frameCount: frameCount,
            presentationTime: presentationTime,
            channelIndex: channelIndex
          )
        })
    } catch {
      return
    }
  }

  private func nextPresentationTime(frameCount: Int) -> CMTime? {
    lock.withLock {
      guard let anchor = timingAnchor.snapshot() else { return nil }
      if anchorGeneration != anchor.generation {
        guard
          let nextClock = try? AudioFramePTSClock(
            sampleRate: AudioSampleBufferNormalizer.sampleRate)
        else {
          return nil
        }
        ptsClock = nextClock
        anchorGeneration = anchor.generation
      }
      return try? ptsClock.nextPresentationTime(
        anchorPresentationTime: anchor.presentationTime,
        frameCount: frameCount
      )
    }
  }
}

private final class ProgramAudioMonitorGeneratedSource: @unchecked Sendable {
  enum Mode {
    case silence
    case sweepSine
  }

  private let sink: ProgramAudioMonitorGeneratedSink
  private let timerQueue = DispatchQueue(label: "tokyo.kaito.ldtx.ProgramAudioMonitor.generated")
  private let timerLock = NSLock()
  private var renderTimer: DispatchSourceTimer?

  init(
    channelIndex: Int32,
    mixer: ProgramAudioMonitorMixer,
    mode: Mode,
    timingAnchor: ProgramAudioMonitorTimingAnchor
  ) throws {
    sink = try ProgramAudioMonitorGeneratedSink(
      channelIndex: channelIndex,
      mixer: mixer,
      mode: mode,
      timingAnchor: timingAnchor
    )
  }

  func start() {
    stop()
    let timer = DispatchSource.makeTimerSource(queue: timerQueue)
    timer.schedule(
      deadline: .now(),
      repeating: .nanoseconds(Int(Self.frameDurationNanoseconds)),
      leeway: .milliseconds(1)
    )
    timer.setEventHandler { [weak self] in
      self?.renderTick()
    }
    timerLock.withLock { renderTimer = timer }
    timer.resume()
  }

  func stop() {
    let timer = timerLock.withLock { () -> DispatchSourceTimer? in
      let timer = renderTimer
      renderTimer = nil
      return timer
    }
    timer?.setEventHandler {}
    timer?.cancel()
  }

  private func renderTick() {
    sink.render()
  }

  private static let frameDurationNanoseconds = UInt64(
    max(
      1,
      1_000_000_000 * ProgramAudioMonitorGeneratedSink.frameCount
        / AudioSampleBufferNormalizer.sampleRate
    ))
}

private final class ProgramAudioMonitorGeneratedSink: @unchecked Sendable {
  static let frameCount = 1_024

  private let lock = NSLock()
  private let channelIndex: Int32
  private let mixer: ProgramAudioMonitorMixer
  private let mode: ProgramAudioMonitorGeneratedSource.Mode
  private let timingAnchor: ProgramAudioMonitorTimingAnchor
  private var ptsClock: AudioFramePTSClock
  private var anchorGeneration: Int?
  private var phase: Float = 0
  private var amplitudePhase: Float = 0

  init(
    channelIndex: Int32,
    mixer: ProgramAudioMonitorMixer,
    mode: ProgramAudioMonitorGeneratedSource.Mode,
    timingAnchor: ProgramAudioMonitorTimingAnchor
  ) throws {
    self.channelIndex = channelIndex
    self.mixer = mixer
    self.mode = mode
    self.timingAnchor = timingAnchor
    ptsClock = try AudioFramePTSClock(sampleRate: AudioSampleBufferNormalizer.sampleRate)
  }

  func render() {
    let frameCount = Self.frameCount
    let presentationTime = nextPresentationTime(frameCount: frameCount)

    let channelCount = AudioSampleBufferNormalizer.channelCount
    let phaseStep = 2 * Float.pi * 440 / Float(AudioSampleBufferNormalizer.sampleRate)
    let amplitude =
      switch mode {
      case .silence:
        Float(0)
      case .sweepSine:
        Float(0.08 + 0.35 * (0.5 + 0.5 * sin(amplitudePhase)))
      }
    amplitudePhase += 0.09
    if amplitudePhase > 2 * Float.pi {
      amplitudePhase -= 2 * Float.pi
    }

    var samples = [Float32](repeating: 0, count: frameCount * channelCount)
    for frame in 0..<frameCount {
      let sample = sin(phase) * amplitude
      phase += phaseStep
      if phase > 2 * Float.pi {
        phase -= 2 * Float.pi
      }

      let offset = frame * channelCount
      for channel in 0..<channelCount {
        samples[offset + channel] = sample
      }
    }

    mixer.measurePeak(
      samples: samples,
      frameCount: frameCount,
      channelIndex: channelIndex
    )

    guard let presentationTime else { return }
    mixer.insert(
      samples: samples,
      frameCount: frameCount,
      presentationTime: presentationTime,
      channelIndex: channelIndex
    )
  }

  private func nextPresentationTime(frameCount: Int) -> CMTime? {
    lock.withLock {
      guard let anchor = timingAnchor.snapshot() else { return nil }
      if anchorGeneration != anchor.generation {
        guard
          let nextClock = try? AudioFramePTSClock(
            sampleRate: AudioSampleBufferNormalizer.sampleRate)
        else {
          return nil
        }
        ptsClock = nextClock
        anchorGeneration = anchor.generation
      }
      return try? ptsClock.nextPresentationTime(
        anchorPresentationTime: anchor.presentationTime,
        frameCount: frameCount
      )
    }
  }
}

private final class ProgramAudioMonitorOutputDriver: @unchecked Sendable {
  private let sink: ProgramAudioMonitorOutputDriverSink
  private let timerQueue = DispatchQueue(label: "tokyo.kaito.ldtx.ProgramAudioMonitor.output")
  private let timerLock = NSLock()
  private var renderTimer: DispatchSourceTimer?

  init(
    mixer: ProgramAudioMonitorMixer,
    timingAnchor: ProgramAudioMonitorTimingAnchor,
    expectedChannelIndices: Set<Int32>,
    scheduler: any ProgramRuntimeScheduling
  ) throws {
    sink = try ProgramAudioMonitorOutputDriverSink(
      mixer: mixer,
      timingAnchor: timingAnchor,
      expectedChannelIndices: expectedChannelIndices,
      scheduler: scheduler
    )
  }

  func start() {
    stop()
    let timer = DispatchSource.makeTimerSource(queue: timerQueue)
    timer.schedule(
      deadline: .now(),
      repeating: .milliseconds(5),
      leeway: .milliseconds(1)
    )
    timer.setEventHandler { [weak self] in
      self?.renderTick()
    }
    timerLock.withLock { renderTimer = timer }
    timer.resume()
  }

  func stop() {
    let timer = timerLock.withLock { () -> DispatchSourceTimer? in
      let timer = renderTimer
      renderTimer = nil
      return timer
    }
    timer?.setEventHandler {}
    timer?.cancel()
  }

  private func renderTick() {
    sink.render()
  }
}

final class ProgramAudioMonitorOutputDriverSink: @unchecked Sendable {
  static let frameCount = 1_024

  private let lock = NSLock()
  private let mixer: ProgramAudioMonitorMixer
  private let timingAnchor: ProgramAudioMonitorTimingAnchor
  private let expectedChannelIndices: Set<Int32>
  private let scheduler: any ProgramRuntimeScheduling
  private var ptsClock: AudioFramePTSClock
  private var anchorGeneration: Int?
  private var nextDeadlineNanoseconds: UInt64?
  private var underflowCount = 0

  init(
    mixer: ProgramAudioMonitorMixer,
    timingAnchor: ProgramAudioMonitorTimingAnchor,
    expectedChannelIndices: Set<Int32>,
    scheduler: any ProgramRuntimeScheduling = SystemProgramRuntimeScheduler()
  ) throws {
    self.mixer = mixer
    self.timingAnchor = timingAnchor
    self.expectedChannelIndices = expectedChannelIndices
    self.scheduler = scheduler
    ptsClock = try AudioFramePTSClock(sampleRate: AudioSampleBufferNormalizer.sampleRate)
  }

  func render() {
    for _ in 0..<Self.maximumCatchUpBlockCount {
      let frameCount = Self.frameCount
      guard let presentationTime = nextPresentationTime(frameCount: frameCount) else {
        return
      }
      let missingChannelIndices = mixer.render(
        frameCount: frameCount,
        presentationTime: presentationTime,
        expectedChannelIndices: expectedChannelIndices
      )
      if !missingChannelIndices.isEmpty {
        underflowCount += 1
        if underflowCount == 1 || underflowCount.isMultiple(of: 120) {
          programAudioMonitorLogger.error(
            "Program audio deadline expired before all sources arrived underflowCount=\(self.underflowCount, privacy: .public) missingChannelIndices=\(missingChannelIndices.map(String.init).joined(separator: ","), privacy: .public) ptsValue=\(presentationTime.value, privacy: .public) ptsTimescale=\(presentationTime.timescale, privacy: .public)"
          )
        }
      }
    }
  }

  private func nextPresentationTime(frameCount: Int) -> CMTime? {
    lock.withLock {
      guard let anchor = timingAnchor.snapshot() else { return nil }
      if anchorGeneration != anchor.generation {
        guard
          let nextClock = try? AudioFramePTSClock(
            sampleRate: AudioSampleBufferNormalizer.sampleRate)
        else {
          return nil
        }
        ptsClock = nextClock
        anchorGeneration = anchor.generation
        nextDeadlineNanoseconds =
          scheduler.nowNanoseconds
          + Self.targetLatencyNanoseconds
        return nil
      }
      guard let deadline = nextDeadlineNanoseconds,
        scheduler.nowNanoseconds >= deadline
      else {
        return nil
      }
      guard
        let presentationTime = try? ptsClock.nextPresentationTime(
          anchorPresentationTime: anchor.presentationTime,
          frameCount: frameCount
        )
      else {
        return nil
      }
      nextDeadlineNanoseconds = deadline + Self.frameDurationNanoseconds
      return presentationTime
    }
  }

  private static let targetLatencyNanoseconds: UInt64 = 200_000_000
  private static let frameDurationNanoseconds = UInt64(
    max(
      1,
      1_000_000_000 * frameCount / AudioSampleBufferNormalizer.sampleRate
    ))
  private static let maximumCatchUpBlockCount = 8
}

final class ProgramAudioMonitorMixer: @unchecked Sendable {
  private let lock = NSLock()
  private var audioEngine: LDTXAudioMixEngine
  private let channelCount: Int32
  private let output: ProgramAudioMonitorOutput
  private var timelinesByChannelIndex: [Int32: AudioChannelTimeline] = [:]

  init(
    audioEngine: LDTXAudioMixEngine,
    channelCount: Int32,
    output: ProgramAudioMonitorOutput
  ) throws {
    self.audioEngine = audioEngine
    self.channelCount = channelCount
    self.output = output
    for channelIndex in 0..<channelCount {
      timelinesByChannelIndex[channelIndex] = try AudioChannelTimeline(
        sampleRate: AudioSampleBufferNormalizer.sampleRate,
        channelCount: AudioSampleBufferNormalizer.channelCount
      )
    }
  }

  func insert(
    samples: [Float32],
    frameCount: Int,
    presentationTime: CMTime,
    channelIndex: Int32
  ) {
    samples.withUnsafeBufferPointer { samples in
      insert(
        samples: samples,
        frameCount: frameCount,
        presentationTime: presentationTime,
        channelIndex: channelIndex
      )
    }
  }

  func measurePeak(
    samples: [Float32],
    frameCount: Int,
    channelIndex: Int32
  ) {
    samples.withUnsafeBufferPointer { samples in
      measurePeak(
        samples: samples,
        frameCount: frameCount,
        channelIndex: channelIndex
      )
    }
  }

  func measurePeak(
    samples: UnsafeBufferPointer<Float32>,
    frameCount: Int,
    channelIndex: Int32
  ) {
    audioEngine.measurePeakInterleavedFloat32(
      channelIndex,
      samples.baseAddress,
      Int32(frameCount),
      Int32(AudioSampleBufferNormalizer.channelCount)
    )
  }

  func insert(
    samples: UnsafeBufferPointer<Float32>,
    frameCount: Int,
    presentationTime: CMTime,
    channelIndex: Int32
  ) {
    lock.withLock {
      guard let timeline = timelinesByChannelIndex[channelIndex] else {
        return
      }
      try? timeline.insert(
        samples: samples,
        frameCount: frameCount,
        presentationTime: presentationTime
      )
    }
  }

  func render(
    frameCount: Int,
    presentationTime: CMTime,
    expectedChannelIndices: Set<Int32>
  ) -> [Int32] {
    let result = mixedSamples(
      frameCount: frameCount,
      presentationTime: presentationTime,
      expectedChannelIndices: expectedChannelIndices
    )
    _ = append(result.samples, frameCount: frameCount, presentationTime: presentationTime)
    return result.missingChannelIndices
  }

  func mixedSamples(
    frameCount: Int,
    presentationTime: CMTime,
    expectedChannelIndices: Set<Int32>
  ) -> (samples: [Float32], missingChannelIndices: [Int32]) {
    lock.withLock {
      let missingChannelIndices = expectedChannelIndices.sorted().filter { channelIndex in
        guard let timeline = timelinesByChannelIndex[channelIndex] else {
          return true
        }
        return
          (try? timeline.hasCompleteRange(
            presentationTime: presentationTime,
            frameCount: frameCount
          )) != true
      }
      return (
        makeMixedSamples(
          frameCount: frameCount,
          readPresentationTime: presentationTime,
          skippedChannelIndices: Set(missingChannelIndices)
        ),
        missingChannelIndices
      )
    }
  }

  private func makeMixedSamples(
    frameCount: Int,
    readPresentationTime: CMTime,
    skippedChannelIndices: Set<Int32>
  ) -> [Float32] {
    let channelSampleCount = frameCount * AudioSampleBufferNormalizer.channelCount
    var mixedSamples = [Float32](repeating: 0, count: channelSampleCount)
    guard frameCount > 0 else { return mixedSamples }

    for channelIndex in 0..<channelCount {
      guard !skippedChannelIndices.contains(channelIndex) else {
        continue
      }
      guard let timeline = timelinesByChannelIndex[channelIndex] else {
        continue
      }
      let sourceSamples: [Float32]
      do {
        sourceSamples = try timeline.read(
          presentationTime: readPresentationTime,
          frameCount: frameCount
        )
      } catch {
        continue
      }

      sourceSamples.withUnsafeBufferPointer { inputBuffer in
        mixedSamples.withUnsafeMutableBufferPointer { outputBuffer in
          audioEngine.mixInterleavedFloat32(
            channelIndex,
            inputBuffer.baseAddress,
            outputBuffer.baseAddress,
            Int32(frameCount),
            Int32(AudioSampleBufferNormalizer.channelCount),
            false
          )
        }
      }
    }
    return mixedSamples
  }

  private func append(_ samples: [Float32]?, frameCount: Int, presentationTime: CMTime) -> Bool {
    guard let samples,
      let sampleBuffer = ProgramAudioMonitorSampleBufferFactory.makeSampleBuffer(
        samples: samples,
        frameCount: frameCount,
        presentationTime: presentationTime,
        formatDescription: nil
      )
    else {
      return false
    }
    return output.append(sampleBuffer)
  }
}

final class ProgramAudioMonitorOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var sampleHandlers: [UUID: @Sendable (CMSampleBuffer) -> Void] = [:]
  private var lastPresentationTime: CMTime?

  init(sampleHandler: (@Sendable (CMSampleBuffer) -> Void)? = nil) {
    if let sampleHandler {
      sampleHandlers[UUID()] = sampleHandler
    }
  }

  func addSampleHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) -> UUID {
    lock.withLock {
      let id = UUID()
      sampleHandlers[id] = handler
      return id
    }
  }

  func removeSampleHandler(id: UUID) {
    lock.withLock { sampleHandlers[id] = nil }
  }

  func resetTimeline() {
    lock.withLock { lastPresentationTime = nil }
  }

  func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
    let handlers: [@Sendable (CMSampleBuffer) -> Void]? = lock.withLock {
      let presentationTime = sampleBuffer.presentationTimeStamp
      guard presentationTime.isValid else {
        return nil
      }
      if let lastPresentationTime,
        CMTimeCompare(presentationTime, lastPresentationTime) <= 0
      {
        return nil
      }
      lastPresentationTime = presentationTime
      return Array(sampleHandlers.values)
    }
    guard let handlers else { return false }
    for handler in handlers {
      handler(sampleBuffer)
    }
    return !handlers.isEmpty
  }
}

private enum ProgramAudioMonitorSampleBufferFactory {
  private static let sharedFormatDescription = makeAudioFormatDescription()

  static func makeSampleBuffer(
    samples: [Float32],
    frameCount: Int,
    presentationTime: CMTime,
    formatDescription providedFormatDescription: CMFormatDescription?
  ) -> CMSampleBuffer? {
    let byteCount = samples.count * MemoryLayout<Float32>.stride
    guard frameCount > 0, byteCount > 0 else {
      return nil
    }

    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: byteCount,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: byteCount,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
      return nil
    }

    let replaceStatus = samples.withUnsafeBytes { buffer in
      CMBlockBufferReplaceDataBytes(
        with: buffer.baseAddress!,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: byteCount
      )
    }
    guard replaceStatus == kCMBlockBufferNoErr else {
      return nil
    }

    let formatDescription: CMFormatDescription
    if let providedFormatDescription {
      formatDescription = providedFormatDescription
    } else if let generatedFormatDescription = sharedFormatDescription {
      formatDescription = generatedFormatDescription
    } else {
      return nil
    }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: CMTimeScale(AudioSampleBufferNormalizer.sampleRate)),
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: frameCount,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr else {
      return nil
    }
    return sampleBuffer
  }

  private static func makeAudioFormatDescription() -> CMAudioFormatDescription? {
    var streamDescription = AudioStreamBasicDescription(
      mSampleRate: Float64(AudioSampleBufferNormalizer.sampleRate),
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(
        AudioSampleBufferNormalizer.channelCount * MemoryLayout<Float32>.stride),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(
        AudioSampleBufferNormalizer.channelCount * MemoryLayout<Float32>.stride),
      mChannelsPerFrame: UInt32(AudioSampleBufferNormalizer.channelCount),
      mBitsPerChannel: UInt32(MemoryLayout<Float32>.stride * 8),
      mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &streamDescription,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDescription
    )
    guard status == noErr else {
      return nil
    }
    return formatDescription
  }
}
