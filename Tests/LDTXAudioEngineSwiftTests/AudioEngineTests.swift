// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXAudioEngine.Cxx
import Testing

@Suite
struct AudioEngineSwiftTests {
  @Test
  func timelineRoundTripsStereoSamples() {
    var timeline = ldtx.audio.Timeline()
    var input: [Float] = [0.25, -0.25, 0.5, -0.5]
    var output = [Float](repeating: 0, count: input.count)

    input.withUnsafeBufferPointer { buffer in
      timeline.insert(buffer.baseAddress, 2, 48_000)
    }
    #expect(timeline.read(&output, 2, 48_000))
    #expect(output == input)
  }

  @Test
  func audioMixEngineAppliesGain() {
    var engine = LDTXAudioMixEngine(1)
    engine.setChannelGain(0, 0.5)
    var input: [Float] = [1, -1]
    var output = [Float](repeating: 0, count: 2)

    input.withUnsafeBufferPointer { inputBuffer in
      output.withUnsafeMutableBufferPointer { outputBuffer in
        engine.mixInterleavedFloat32(
          0, inputBuffer.baseAddress, outputBuffer.baseAddress, 1, 2, true)
      }
    }

    #expect(output == [0.5, -0.5])
    #expect(engine.channelPeak(0) == 0.5)
  }
}
