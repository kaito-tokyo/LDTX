// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import Foundation

private final class SegmentDelegate: NSObject, AVAssetWriterDelegate {
  func assetWriter(
    _ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
    segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?
  ) {}
}

private func check(_ success: Bool, _ message: String) throws {
  if !success {
    throw NSError(
      domain: "PCMWriterReproducer", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }
}

private func sample(format: AVAudioFormat, start: Int, frames: Int) throws -> CMSampleBuffer {
  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
  pcm.frameLength = AVAudioFrameCount(frames)
  let values = pcm.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(
    to: Float.self)
  for frame in 0..<frames {
    let value = Float(sin(2 * Double.pi * 440 * Double(start + frame) / 48_000) * 0.1)
    values[frame * 2] = value
    values[frame * 2 + 1] = value
  }
  var timing = CMSampleTimingInfo(
    duration: CMTime(value: 1, timescale: 48_000),
    presentationTimeStamp: CMTime(value: Int64(start), timescale: 48_000),
    decodeTimeStamp: .invalid)
  var result: CMSampleBuffer?
  try check(
    CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: nil, formatDescription: format.formatDescription,
      sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr,
    "Create sample buffer")
  try check(
    CMSampleBufferSetDataBufferFromAudioBufferList(
      result!, blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
      bufferList: pcm.audioBufferList) == noErr, "Copy PCM data")
  return result!
}

@main private enum Reproducer {
  static func main() async {
    do { try await run() } catch {
      FileHandle.standardError.write(Data("Reproducer error: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func run() async throws {
    let rounds = min(1_000, max(1, Int(CommandLine.arguments.dropFirst().first ?? "300") ?? 300))
    let offset = ProcessInfo.processInfo.environment["LDTX_REPRO_ZERO_OFFSET"] == "1" ? 0 : 9_600
    let automaticSegments = ProcessInfo.processInfo.environment["LDTX_REPRO_SINGLE_SEGMENT"] != "1"
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
      channels: 2, interleaved: true)!
    for round in 1...rounds {
      let delegate = SegmentDelegate()
      let writer = AVAssetWriter(contentType: .mpeg4Movie)
      writer.outputFileTypeProfile = .mpeg4AppleHLS
      writer.preferredOutputSegmentInterval = CMTime(
        value: automaticSegments ? 2 : 10, timescale: 1)
      writer.initialSegmentStartTime = .zero
      writer.delegate = delegate
      let input = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
          AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
        ], sourceFormatHint: format.formatDescription)
      input.expectsMediaDataInRealTime = true
      writer.add(input)
      try writer.start()
      writer.startSession(atSourceTime: .zero)
      let deadline = ContinuousClock.now.advanced(by: .seconds(30))
      for start in stride(from: 0, to: 144_000, by: 1_024) {
        while !input.isReadyForMoreMediaData {
          try check(writer.status == .writing && .now < deadline, "Writer did not become ready")
          try await Task.sleep(for: .milliseconds(1))
        }
        try check(
          input.append(
            try sample(
              format: format, start: start + offset,
              frames: min(1_024, 144_000 - start))), "Append PCM")
      }
      input.markAsFinished()
      await withCheckedContinuation { continuation in
        writer.finishWriting { continuation.resume() }
      }
      try check(writer.status == .completed, writer.error?.localizedDescription ?? "Finish writer")
      withExtendedLifetime(delegate) {}
      FileHandle.standardOutput.write(Data("DIRECT_PCM_WRITER completed round \(round)\n".utf8))
    }
  }
}
