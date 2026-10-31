// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

#include "AudioMixEngine.hpp"
#include "doctest/doctest.h"
#include <vector>

TEST_CASE("LUB-1007: Apply gain processes buffer in place") {
  LDTXAudioMixEngine engine(1);
  engine.setChannelGain(0, -0.25f);
  std::vector<float> samples{1.0f, -1.0f, 0.25f, -0.25f};
  engine.applyGainInterleavedFloat32(0, samples.data(), 2, 2);
  CHECK(samples == std::vector<float>({-0.25f, 0.25f, -0.0625f, 0.0625f}));
  CHECK(engine.channelPeak(0) == doctest::Approx(0.25f));
}

TEST_CASE("LUB-1007: Mix applies initial gain without ramp") {
  LDTXAudioMixEngine engine(1);
  engine.setChannelGain(0, 0.5f);
  const std::vector<float> input{1.0f, -1.0f, 0.25f, -0.25f};
  std::vector<float> output(input.size());
  engine.mixInterleavedFloat32(0, input.data(), output.data(), 2, 2, true);
  CHECK(output == std::vector<float>({0.5f, -0.5f, 0.125f, -0.125f}));
  CHECK(engine.channelPeak(0) == doctest::Approx(0.5f));
}

TEST_CASE("LUB-1007: Measure peak applies gain without mutating samples") {
  LDTXAudioMixEngine engine(1);
  engine.setChannelGain(0, -0.5f);
  const std::vector<float> samples{1.0f, -1.0f, 0.25f, -0.25f};
  engine.measurePeakInterleavedFloat32(0, samples.data(), 2, 2);
  CHECK(samples == std::vector<float>({1.0f, -1.0f, 0.25f, -0.25f}));
  CHECK(engine.channelPeak(0) == doctest::Approx(0.5f));
}

TEST_CASE("LUB-1007: Gain changes ramp across next buffer") {
  LDTXAudioMixEngine engine(1);
  const std::vector<float> input{1.0f, 1.0f, 1.0f, 1.0f};
  std::vector<float> output(input.size());
  engine.mixInterleavedFloat32(0, input.data(), output.data(), 2, 2, true);
  engine.resetChannelPeak(0);
  engine.setChannelGain(0, 0.0f);
  engine.mixInterleavedFloat32(0, input.data(), output.data(), 2, 2, true);
  CHECK(output == std::vector<float>({0.5f, 0.5f, 0.0f, 0.0f}));
  CHECK(engine.channelPeak(0) == doctest::Approx(0.5f));
}

TEST_CASE("LUB-1007: Mix accumulates multiple engine channels") {
  LDTXAudioMixEngine engine(2);
  engine.setChannelGain(0, 0.5f);
  engine.setChannelGain(1, -0.25f);
  const std::vector<float> first{1.0f, 1.0f};
  const std::vector<float> second{1.0f, -1.0f};
  std::vector<float> output(first.size());
  engine.mixInterleavedFloat32(0, first.data(), output.data(), 1, 2, true);
  engine.mixInterleavedFloat32(1, second.data(), output.data(), 1, 2, false);
  CHECK(output == std::vector<float>({0.25f, 0.75f}));
  CHECK(engine.channelPeak(0) == doctest::Approx(0.5f));
  CHECK(engine.channelPeak(1) == doctest::Approx(0.25f));
}

TEST_CASE("LUB-1007: Peak holds maximum until reset") {
  LDTXAudioMixEngine engine(1);
  std::vector<float> loud{0.8f, -0.7f};
  engine.applyGainInterleavedFloat32(0, loud.data(), 1, 2);
  std::vector<float> quiet{0.1f, -0.2f};
  engine.applyGainInterleavedFloat32(0, quiet.data(), 1, 2);
  CHECK(engine.consumeChannelPeak(0) == doctest::Approx(0.8f));
  CHECK(engine.channelPeak(0) == doctest::Approx(0.0f));
}
