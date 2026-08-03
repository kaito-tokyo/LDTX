// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Accelerate
import Combine
import CoreMedia
import Foundation
import LDTXCapture
import LDTXMP4
import OSLog

public struct InputAudioSpectrogramSnapshot: Sendable {
  public var pixels: [UInt8]
  public var columnCapacity: Int
  public var binCount: Int
  public var sampleRate: Int
  public var analysisBandCount: Int

  public init(
    pixels: [UInt8],
    columnCapacity: Int,
    binCount: Int,
    sampleRate: Int,
    analysisBandCount: Int
  ) {
    self.pixels = pixels
    self.columnCapacity = columnCapacity
    self.binCount = binCount
    self.sampleRate = sampleRate
    self.analysisBandCount = analysisBandCount
  }

  public static let empty = InputAudioSpectrogramSnapshot(
    pixels: [],
    columnCapacity: 180,
    binCount: 96,
    sampleRate: AudioSampleBufferNormalizer.sampleRate,
    analysisBandCount: 128
  )
}

public final class InputAudioSpectrogramController: ObservableObject, @unchecked Sendable {
  fileprivate static let logger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "InputAudioSpectrogram"
  )

  @Published public private(set) var snapshot = InputAudioSpectrogramSnapshot.empty
  @Published public private(set) var statusText = "No audio selected"

  private let lock = NSLock()
  private let captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  private let sampleDispatcher = InputAudioSpectrogramSampleDispatcher()
  private var activeAudioDeviceID: String?
  private var subscription: WorkspaceCaptureSessionCoordinator.AudioSubscription?
  private var sessionID = 0

  public init(captureSessionCoordinator: WorkspaceCaptureSessionCoordinator) {
    self.captureSessionCoordinator = captureSessionCoordinator
  }

  public func configure(audioDeviceID: String?) {
    var previousSubscription: WorkspaceCaptureSessionCoordinator.AudioSubscription?
    var nextSessionID = 0
    lock.withLock {
      sessionID += 1
      nextSessionID = sessionID
      activeAudioDeviceID = audioDeviceID
      previousSubscription = subscription
      subscription = nil
    }
    let startedSessionID = nextSessionID

    if let previousSubscription {
      captureSessionCoordinator.unsubscribeAudio(previousSubscription)
    }

    guard let audioDeviceID else {
      Task { @MainActor [weak self] in
        self?.snapshot = .empty
        self?.statusText = "No audio selected"
      }
      return
    }

    Task { @MainActor [weak self] in
      self?.snapshot = .empty
      self?.statusText = "Starting audio preview..."
    }
    Self.logger.notice(
      "Configuring audio spectrogram preview: session=\(startedSessionID, privacy: .public), device=\(audioDeviceID, privacy: .public)"
    )

    Task(priority: .utility) { [weak self] in
      let analyzer: InputAudioSpectrogramAnalyzer
      do {
        analyzer = try InputAudioSpectrogramAnalyzer()
      } catch {
        guard let self else { return }
        guard self.isCurrent(sessionID: startedSessionID, audioDeviceID: audioDeviceID) else {
          return
        }
        await MainActor.run {
          self.snapshot = .empty
          self.statusText = "Audio preview unavailable"
        }
        Self.logger.error(
          "Audio spectrogram analyzer initialization failed: device=\(audioDeviceID, privacy: .public)"
        )
        return
      }

      guard let self else { return }
      guard self.isCurrent(sessionID: startedSessionID, audioDeviceID: audioDeviceID) else {
        return
      }
      let subscription = self.captureSessionCoordinator.subscribeAudio(
        deviceID: audioDeviceID,
        failureHandler: { [weak self] failure in
          self?.handleCaptureFailure(
            failure, sessionID: startedSessionID, audioDeviceID: audioDeviceID)
        },
        sampleHandler: { [weak self] captureSampleBuffer in
          guard let self else { return }
          let sampleBuffer: CMSampleBuffer
          do {
            sampleBuffer = try ProgramOwnedPCMSampleBuffer(copying: captureSampleBuffer).value
          } catch {
            self.handleSampleCopyFailure(error, sessionID: startedSessionID, audioDeviceID: audioDeviceID)
            return
          }
          self.sampleDispatcher.enqueue(sampleBuffer) { [weak self] sampleBuffer in
            guard let self,
              self.isCurrent(sessionID: startedSessionID, audioDeviceID: audioDeviceID)
            else { return }
            self.consume(sampleBuffer, analyzer: analyzer, sessionID: startedSessionID)
          }
        },
        completionHandler: { [weak self] result in
          guard let self else { return }
          guard self.isCurrent(sessionID: startedSessionID, audioDeviceID: audioDeviceID) else {
            return
          }
          switch result {
          case .success:
            Task { @MainActor [weak self] in
              self?.statusText = "48 kHz / 128-band DPSS PFB"
            }
            Self.logger.notice(
              "Audio spectrogram capture started: session=\(startedSessionID, privacy: .public), device=\(audioDeviceID, privacy: .public)"
            )
          case .failure(let error):
            Task { @MainActor [weak self] in
              self?.snapshot = .empty
              self?.statusText = "Audio preview unavailable"
            }
            Self.logger.error(
              "Audio spectrogram capture failed: session=\(startedSessionID, privacy: .public), device=\(audioDeviceID, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
            )
          }
        }
      )
      let registered = self.lock.withLock { () -> Bool in
        guard self.sessionID == startedSessionID else { return false }
        self.subscription = subscription
        return true
      }
      if !registered {
        self.captureSessionCoordinator.unsubscribeAudio(subscription)
      }
    }
  }

  public func stop() {
    var previousSubscription: WorkspaceCaptureSessionCoordinator.AudioSubscription?
    lock.withLock {
      sessionID += 1
      activeAudioDeviceID = nil
      previousSubscription = subscription
      subscription = nil
    }
    if let previousSubscription {
      captureSessionCoordinator.unsubscribeAudio(previousSubscription)
    }
  }

  private func consume(
    _ sampleBuffer: CMSampleBuffer,
    analyzer: InputAudioSpectrogramAnalyzer,
    sessionID: Int
  ) {
    guard let snapshot = analyzer.append(sampleBuffer) else {
      return
    }
    guard isCurrent(sessionID: sessionID) else {
      return
    }
    Task { @MainActor [weak self] in
      guard let self,
        self.isCurrent(sessionID: sessionID)
      else {
        return
      }
      self.snapshot = snapshot
    }
  }

  private func handleCaptureFailure(
    _ failure: CaptureSessionRuntimeFailure,
    sessionID: Int,
    audioDeviceID: String
  ) {
    guard isCurrent(sessionID: sessionID, audioDeviceID: audioDeviceID) else { return }
    Task { @MainActor [weak self] in
      guard let self,
        self.isCurrent(sessionID: sessionID, audioDeviceID: audioDeviceID)
      else { return }
      self.snapshot = .empty
      self.statusText = "Audio preview unavailable"
    }
    Self.logger.error(
      "Audio spectrogram capture runtime failure: session=\(sessionID, privacy: .public), device=\(audioDeviceID, privacy: .public), error=\(failure.localizedDescription, privacy: .public)"
    )
  }

  private func handleSampleCopyFailure(
    _ error: Error,
    sessionID: Int,
    audioDeviceID: String
  ) {
    guard isCurrent(sessionID: sessionID, audioDeviceID: audioDeviceID) else { return }
    Self.logger.error(
      "Audio spectrogram PCM copy failed: session=\(sessionID, privacy: .public), device=\(audioDeviceID, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
    )
  }

  private func isCurrent(sessionID: Int, audioDeviceID: String? = nil) -> Bool {
    lock.withLock {
      guard self.sessionID == sessionID else {
        return false
      }
      if let audioDeviceID {
        return activeAudioDeviceID == audioDeviceID
      }
      return true
    }
  }
}

/// Keeps spectrogram DSP off the shared capture callback and bounds retained
/// work to the newest sample while the analyzer is busy.
private final class InputAudioSpectrogramSampleDispatcher: @unchecked Sendable {
  private struct PendingWork: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let operation: @Sendable (CMSampleBuffer) -> Void
  }

  private let lock = NSLock()
  private let queue = DispatchQueue(
    label: "tokyo.kaito.ldtx.input-audio-spectrogram",
    qos: .utility
  )
  private var pendingWork: PendingWork?
  private var isScheduled = false

  func enqueue(
    _ sampleBuffer: CMSampleBuffer,
    operation: @escaping @Sendable (CMSampleBuffer) -> Void
  ) {
    let shouldSchedule = lock.withLock { () -> Bool in
      pendingWork = PendingWork(sampleBuffer: sampleBuffer, operation: operation)
      guard !isScheduled else { return false }
      isScheduled = true
      return true
    }
    if shouldSchedule { queue.async { [weak self] in self?.processNext() } }
  }

  private func processNext() {
    let work = lock.withLock { () -> PendingWork? in
      let work = pendingWork
      pendingWork = nil
      return work
    }
    work.map { $0.operation($0.sampleBuffer) }

    let shouldSchedule = lock.withLock { () -> Bool in
      guard pendingWork != nil else {
        isScheduled = false
        return false
      }
      return true
    }
    if shouldSchedule { queue.async { [weak self] in self?.processNext() } }
  }
}

private final class InputAudioSpectrogramAnalyzer: @unchecked Sendable {
  private enum Constants {
    static let channelCount = 256
    static let analysisBandCount = channelCount / 2
    static let tapsPerChannel = 6
    static let prototypeLength = channelCount * tapsPerChannel
    static let analysisHopSamples = channelCount
    static let displayFrameDecimation = 4
    static let bandPowerLowPassAlpha: Float = 0.32
    static let binCount = 96
    static let columnCapacity = 180
    static let minimumDecibels: Float = -96
    static let maximumDecibels: Float = 0
    static let displayGainDecibels: Float = 30
    static let publishIntervalSeconds = 1.0 / 15.0
    static let minimumFrequency: Float = 32
    static let epsilon: Float = 0.000_000_1
    static let dftForward: Int32 = 1
    static let prototypeHalfBandwidth = 0.5 / Double(channelCount)
    static let dpssIterationCount = 18
  }

  private let normalizer: AudioSampleBufferNormalizer
  private let dftSetup: vDSP_DFT_Setup
  private let prototype: [Float]
  private let binRanges: [Range<Int>]
  private var analysisReal = [Float](repeating: 0, count: Constants.channelCount)
  private var analysisImag = [Float](repeating: 0, count: Constants.channelCount)
  private var pendingMonoSamples: [Float] = []
  private var pendingMonoSampleStartIndex = 0
  private var outputReal = [Float](repeating: 0, count: Constants.channelCount)
  private var outputImag = [Float](repeating: 0, count: Constants.channelCount)
  private var filteredBandPowers = [Float](repeating: 0, count: Constants.analysisBandCount)
  private var hasInitializedBandPowerFilter = false
  private var analysisFramesSinceLastColumn = 0
  private var columnPixels = [UInt8](
    repeating: 0,
    count: Constants.columnCapacity * Constants.binCount
  )
  private var publishedPixelsRing = (0..<3).map { _ in
    [UInt8](repeating: 0, count: Constants.columnCapacity * Constants.binCount)
  }
  private var storedColumnCount = 0
  private var nextColumnIndex = 0
  private var nextPublishedPixelsIndex = 0
  private var lastPublishedAt = 0.0
  private var hasLoggedFirstNormalizedBuffer = false
  private var hasLoggedFirstColumn = false
  private var hasLoggedNormalizeFailure = false
  private static let sharedPrototype = makeDPSSPrototype(
    length: Constants.prototypeLength,
    halfBandwidth: Constants.prototypeHalfBandwidth,
    iterationCount: Constants.dpssIterationCount
  )
  private static let sharedBinRanges = makeBinRanges()

  init() throws {
    normalizer = try AudioSampleBufferNormalizer()
    guard
      let dftSetup = vDSP_DFT_zrop_CreateSetup(
        nil,
        vDSP_Length(Constants.channelCount),
        vDSP_DFT_Direction(rawValue: Constants.dftForward)!
      )
    else {
      throw InputAudioSpectrogramAnalyzerError.fftSetupFailed
    }
    self.dftSetup = dftSetup

    prototype = Self.sharedPrototype
    binRanges = Self.sharedBinRanges
  }

  deinit {
    vDSP_DFT_DestroySetup(dftSetup)
  }

  func append(_ sampleBuffer: CMSampleBuffer) -> InputAudioSpectrogramSnapshot? {
    do {
      guard
        let snapshot = try normalizer.withNormalizedFloat32Samples(
          sampleBuffer,
          { [self] samples, frameCount -> InputAudioSpectrogramSnapshot? in
            if !hasLoggedFirstNormalizedBuffer {
              hasLoggedFirstNormalizedBuffer = true
              InputAudioSpectrogramController.logger.notice(
                "Audio spectrogram received first normalized buffer: pts=\(sampleBuffer.presentationTimeStamp.seconds, privacy: .public), samples=\(frameCount, privacy: .public)"
              )
            }

            appendMonoSamples(
              fromInterleavedStereoSamples: samples,
              sampleCount: samples.count
            )

            var renderedColumn = false
            while availablePendingMonoSampleCount >= Constants.prototypeLength {
              updateFilteredBandPowers()
              analysisFramesSinceLastColumn += 1
              if analysisFramesSinceLastColumn == Constants.displayFrameDecimation {
                writeSpectrumColumn(fromBandPowers: filteredBandPowers)
                analysisFramesSinceLastColumn = 0
                renderedColumn = true
                if !hasLoggedFirstColumn {
                  hasLoggedFirstColumn = true
                  InputAudioSpectrogramController.logger.notice(
                    "Audio spectrogram rendered first column"
                  )
                }
              }
              pendingMonoSampleStartIndex += Constants.analysisHopSamples
            }
            compactPendingMonoSamplesIfNeeded()

            let now = ProcessInfo.processInfo.systemUptime
            guard renderedColumn,
              now - lastPublishedAt >= Constants.publishIntervalSeconds
            else {
              return nil
            }

            lastPublishedAt = now
            return InputAudioSpectrogramSnapshot(
              pixels: makePublishedPixels(),
              columnCapacity: Constants.columnCapacity,
              binCount: Constants.binCount,
              sampleRate: AudioSampleBufferNormalizer.sampleRate,
              analysisBandCount: Constants.analysisBandCount
            )
          }
        )
      else {
        if !hasLoggedNormalizeFailure {
          hasLoggedNormalizeFailure = true
          InputAudioSpectrogramController.logger.error(
            "Audio spectrogram normalization produced no output buffer"
          )
        }
        return nil
      }
      return snapshot
    } catch {
      if !hasLoggedNormalizeFailure {
        hasLoggedNormalizeFailure = true
        InputAudioSpectrogramController.logger.error(
          "Audio spectrogram append failed: \(error.localizedDescription, privacy: .public)"
        )
      }
      return nil
    }
  }

  private var availablePendingMonoSampleCount: Int {
    pendingMonoSamples.count - pendingMonoSampleStartIndex
  }

  private func appendMonoSamples(
    fromInterleavedStereoSamples samples: UnsafeBufferPointer<Float32>,
    sampleCount: Int
  ) {
    pendingMonoSamples.reserveCapacity(pendingMonoSamples.count + (sampleCount / 2))
    guard sampleCount >= 2 else {
      return
    }
    var index = 0
    while index < sampleCount - 1 {
      pendingMonoSamples.append((samples[index] + samples[index + 1]) * 0.5)
      index += 2
    }
  }

  private func updateFilteredBandPowers() {
    let windowStart = pendingMonoSampleStartIndex
    let channelCount = Constants.channelCount
    let tapsPerChannel = Constants.tapsPerChannel
    let analysisBandCount = Constants.analysisBandCount
    var index = 0
    while index < channelCount {
      var sampleIndex = windowStart + index
      var prototypeIndex = index
      var accumulated: Float = 0
      var tapIndex = 0
      while tapIndex < tapsPerChannel {
        accumulated += pendingMonoSamples[sampleIndex] * prototype[prototypeIndex]
        sampleIndex += channelCount
        prototypeIndex += channelCount
        tapIndex += 1
      }
      analysisReal[index] = accumulated
      analysisImag[index] = 0
      index += 1
    }

    vDSP_DFT_Execute(
      dftSetup,
      &analysisReal,
      &analysisImag,
      &outputReal,
      &outputImag
    )

    let shouldBlend = hasInitializedBandPowerFilter
    let alpha = Constants.bandPowerLowPassAlpha
    let beta = 1 - alpha
    var bandIndex = 0
    while bandIndex < analysisBandCount {
      let fftIndex = bandIndex + 1
      let power =
        outputReal[fftIndex] * outputReal[fftIndex] + outputImag[fftIndex] * outputImag[fftIndex]
      if shouldBlend {
        filteredBandPowers[bandIndex] = beta * filteredBandPowers[bandIndex] + alpha * power
      } else {
        filteredBandPowers[bandIndex] = power
      }
      bandIndex += 1
    }
    hasInitializedBandPowerFilter = true
  }

  private func writeSpectrumColumn(fromBandPowers bandPowers: [Float]) {
    let binCount = Constants.binCount
    let channelCountScale = Float(Constants.channelCount)
    let baseOffset = nextColumnIndex * binCount
    var binIndex = 0
    while binIndex < binCount {
      let range = binRanges[binIndex]
      var accumulatedPower: Float = 0
      var bandIndex = range.lowerBound
      while bandIndex < range.upperBound {
        accumulatedPower += bandPowers[bandIndex]
        bandIndex += 1
      }
      let rangeCount = max(range.upperBound - range.lowerBound, 1)
      let meanPower = accumulatedPower / Float(rangeCount)
      let magnitude = sqrt(meanPower) / channelCountScale
      let decibels = 20 * log10(max(magnitude, Constants.epsilon)) + Constants.displayGainDecibels
      let normalized = min(
        max(
          (decibels - Constants.minimumDecibels)
            / (Constants.maximumDecibels - Constants.minimumDecibels),
          0
        ),
        1
      )
      let intensity = pow(normalized, 0.75)
      columnPixels[baseOffset + binIndex] = UInt8(max(0, min(255, Int(intensity * 255))))
      binIndex += 1
    }

    nextColumnIndex = (nextColumnIndex + 1) % Constants.columnCapacity
    storedColumnCount = min(storedColumnCount + 1, Constants.columnCapacity)
  }

  private func makePublishedPixels() -> [UInt8] {
    guard storedColumnCount > 0 else {
      return []
    }

    let columnCapacity = Constants.columnCapacity
    let binCount = Constants.binCount
    let publishedPixelsIndex = nextPublishedPixelsIndex
    nextPublishedPixelsIndex = (nextPublishedPixelsIndex + 1) % publishedPixelsRing.count
    var pixels = publishedPixelsRing[publishedPixelsIndex]
    _ = pixels.withUnsafeMutableBytes { buffer in
      memset(buffer.baseAddress!, 0, buffer.count)
    }
    let oldestColumnIndex = storedColumnCount == columnCapacity ? nextColumnIndex : 0
    let xOffset = columnCapacity - storedColumnCount
    var displayColumnIndex = 0
    while displayColumnIndex < storedColumnCount {
      let sourceColumnIndex = (oldestColumnIndex + displayColumnIndex) % columnCapacity
      let sourceOffset = sourceColumnIndex * binCount
      let x = xOffset + displayColumnIndex
      var binIndex = 0
      while binIndex < binCount {
        let y = binCount - binIndex - 1
        pixels[y * columnCapacity + x] = columnPixels[sourceOffset + binIndex]
        binIndex += 1
      }
      displayColumnIndex += 1
    }
    publishedPixelsRing[publishedPixelsIndex] = pixels
    return pixels
  }

  private func compactPendingMonoSamplesIfNeeded() {
    guard pendingMonoSampleStartIndex >= Constants.prototypeLength else {
      return
    }
    pendingMonoSamples.removeFirst(pendingMonoSampleStartIndex)
    pendingMonoSampleStartIndex = 0
  }

  private static func makeBinRanges() -> [Range<Int>] {
    let nyquist = Float(AudioSampleBufferNormalizer.sampleRate) * 0.5
    let logMin = log(Constants.minimumFrequency)
    let logMax = log(nyquist)
    return (0..<Constants.binCount).map { binIndex in
      let startUnit = Float(binIndex) / Float(Constants.binCount)
      let endUnit = Float(binIndex + 1) / Float(Constants.binCount)
      let startFrequency = exp(logMin + (logMax - logMin) * startUnit)
      let endFrequency = exp(logMin + (logMax - logMin) * endUnit)
      let startIndex =
        max(
          Int(startFrequency / nyquist * Float(Constants.analysisBandCount)),
          1
        ) - 1
      let endIndex = min(
        max(Int(endFrequency / nyquist * Float(Constants.analysisBandCount)), startIndex + 2),
        Constants.analysisBandCount
      )
      return startIndex..<endIndex
    }
  }

  private static func makeDPSSPrototype(
    length: Int,
    halfBandwidth: Double,
    iterationCount: Int
  ) -> [Float] {
    let diagonalValue = 2 * halfBandwidth
    let kernel = (0..<length).map { offset -> Double in
      guard offset > 0 else {
        return diagonalValue
      }
      let x = 2 * Double.pi * halfBandwidth * Double(offset)
      return sin(x) / (Double.pi * Double(offset))
    }

    var vector = [Double](repeating: 1.0 / sqrt(Double(length)), count: length)
    var next = [Double](repeating: 0, count: length)

    for _ in 0..<iterationCount {
      for index in 0..<length {
        var value = 0.0
        for sourceIndex in 0..<length {
          value += kernel[abs(index - sourceIndex)] * vector[sourceIndex]
        }
        next[index] = value
      }

      symmetrize(&next)

      let norm = sqrt(
        next.reduce(0.0) { partial, value in
          partial + value * value
        })
      guard norm > 0 else {
        break
      }
      for index in 0..<length {
        next[index] /= norm
      }
      swap(&vector, &next)
    }

    return vector.map(Float.init)
  }

  private static func symmetrize(_ values: inout [Double]) {
    var left = 0
    var right = values.count - 1
    while left < right {
      let average = (values[left] + values[right]) * 0.5
      values[left] = average
      values[right] = average
      left += 1
      right -= 1
    }
  }
}

private enum InputAudioSpectrogramAnalyzerError: Error {
  case fftSetupFailed
}
