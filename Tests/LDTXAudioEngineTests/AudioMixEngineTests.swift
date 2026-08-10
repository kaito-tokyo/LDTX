// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAudioEngine
import Testing

struct AudioMixEngineTests {
  @Test func applyGainProcessesBufferInPlace() {
    var engine = LDTXAudioMixEngine(1)
    engine.setChannelGain(0, -0.25)
    var samples: [Float] = [1.0, -1.0, 0.25, -0.25]

    samples.withUnsafeMutableBufferPointer { sampleBuffer in
      engine.applyGainInterleavedFloat32(
        0,
        sampleBuffer.baseAddress,
        2,
        2
      )
    }

    #expect(samples == [-0.25, 0.25, -0.0625, 0.0625])
    #expect(abs(engine.channelPeak(0) - 0.25) <= 0.0001)
  }

  @Test func mixAppliesInitialGainWithoutRamp() {
    var engine = LDTXAudioMixEngine(1)
    engine.setChannelGain(0, 0.5)
    let input: [Float] = [1.0, -1.0, 0.25, -0.25]
    var output = [Float](repeating: 0, count: input.count)

    input.withUnsafeBufferPointer { inputBuffer in
      output.withUnsafeMutableBufferPointer { outputBuffer in
        engine.mixInterleavedFloat32(
          0,
          inputBuffer.baseAddress,
          outputBuffer.baseAddress,
          2,
          2,
          true
        )
      }
    }

    #expect(output == [0.5, -0.5, 0.125, -0.125])
    #expect(abs(engine.channelPeak(0) - 0.5) <= 0.0001)
  }

  @Test func measurePeakAppliesGainWithoutMutatingSamples() {
    var engine = LDTXAudioMixEngine(1)
    engine.setChannelGain(0, -0.5)
    let samples: [Float] = [1.0, -1.0, 0.25, -0.25]

    samples.withUnsafeBufferPointer { sampleBuffer in
      engine.measurePeakInterleavedFloat32(
        0,
        sampleBuffer.baseAddress,
        2,
        2
      )
    }

    #expect(samples == [1.0, -1.0, 0.25, -0.25])
    #expect(abs(engine.channelPeak(0) - 0.5) <= 0.0001)
  }

  @Test func gainChangesRampAcrossNextBuffer() {
    var engine = LDTXAudioMixEngine(1)
    let warmupInput: [Float] = [1.0, 1.0, 1.0, 1.0]
    var warmupOutput = [Float](repeating: 0, count: warmupInput.count)
    warmupInput.withUnsafeBufferPointer { inputBuffer in
      warmupOutput.withUnsafeMutableBufferPointer { outputBuffer in
        engine.mixInterleavedFloat32(
          0,
          inputBuffer.baseAddress,
          outputBuffer.baseAddress,
          2,
          2,
          true
        )
      }
    }

    engine.resetChannelPeak(0)
    engine.setChannelGain(0, 0.0)
    let input: [Float] = [1.0, 1.0, 1.0, 1.0]
    var output = [Float](repeating: 0, count: input.count)
    input.withUnsafeBufferPointer { inputBuffer in
      output.withUnsafeMutableBufferPointer { outputBuffer in
        engine.mixInterleavedFloat32(
          0,
          inputBuffer.baseAddress,
          outputBuffer.baseAddress,
          2,
          2,
          true
        )
      }
    }

    #expect(output == [0.5, 0.5, 0.0, 0.0])
    #expect(abs(engine.channelPeak(0) - 0.5) <= 0.0001)
  }

  @Test func mixAccumulatesMultipleEngineChannels() {
    var engine = LDTXAudioMixEngine(2)
    engine.setChannelGain(0, 0.5)
    engine.setChannelGain(1, -0.25)
    let firstInput: [Float] = [1.0, 1.0]
    let secondInput: [Float] = [1.0, -1.0]
    var output = [Float](repeating: 0, count: firstInput.count)

    firstInput.withUnsafeBufferPointer { inputBuffer in
      output.withUnsafeMutableBufferPointer { outputBuffer in
        engine.mixInterleavedFloat32(
          0,
          inputBuffer.baseAddress,
          outputBuffer.baseAddress,
          1,
          2,
          true
        )
      }
    }
    secondInput.withUnsafeBufferPointer { inputBuffer in
      output.withUnsafeMutableBufferPointer { outputBuffer in
        engine.mixInterleavedFloat32(
          1,
          inputBuffer.baseAddress,
          outputBuffer.baseAddress,
          1,
          2,
          false
        )
      }
    }

    #expect(output == [0.25, 0.75])
    #expect(abs(engine.channelPeak(0) - 0.5) <= 0.0001)
    #expect(abs(engine.channelPeak(1) - 0.25) <= 0.0001)
  }

  @Test func peakHoldsMaximumUntilReset() {
    var engine = LDTXAudioMixEngine(1)
    var loudSamples: [Float] = [0.8, -0.7]
    loudSamples.withUnsafeMutableBufferPointer { sampleBuffer in
      engine.applyGainInterleavedFloat32(
        0,
        sampleBuffer.baseAddress,
        1,
        2
      )
    }

    var quietSamples: [Float] = [0.1, -0.2]
    quietSamples.withUnsafeMutableBufferPointer { sampleBuffer in
      engine.applyGainInterleavedFloat32(
        0,
        sampleBuffer.baseAddress,
        1,
        2
      )
    }

    #expect(abs(engine.consumeChannelPeak(0) - 0.8) <= 0.0001)
    #expect(abs(engine.channelPeak(0)) <= 0.0001)
  }
}
