// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#include "Internal/AudioTimeline.hpp"
#include "Internal/HALInput.hpp"
#include "Internal/PCMStorage.hpp"
#include "Internal/StopRetry.hpp"
#include "LDTXAudioEngine/WorkspaceAudioEngine.h"
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest/doctest.h"
#include <iostream>
#include <thread>
using namespace ldtx::audio;
TEST_CASE("stop retry") {
  for (unsigned failures = 0; failures <= 4; ++failures) {
    unsigned attempts = 0, waits = 0;
    auto status = retryStop([&] { return ++attempts <= failures ? -50 : 0; }, [&] { ++waits; });
    CHECK(attempts == std::min(failures + 1, 4u));
    CHECK(waits == attempts - 1);
    CHECK(status == (failures == 4 ? -50 : 0));
  }
}
static AudioTimeStamp timestamp(uint64_t ns, double frame = 0) {
  mach_timebase_info_data_t scale;
  mach_timebase_info(&scale);
  AudioTimeStamp t{};
  t.mHostTime = uint64_t(__uint128_t(ns) * scale.denom / scale.numer);
  t.mSampleTime = frame;
  t.mFlags = kAudioTimeStampHostTimeValid | kAudioTimeStampSampleTimeValid;
  return t;
}
struct Samples {
  std::vector<CMTime> pts;
  std::vector<std::vector<float>> pcm;
  static void receive(void *p, CMSampleBufferRef sample) {
    auto &s = *static_cast<Samples *>(p);
    s.pts.push_back(CMSampleBufferGetPresentationTimeStamp(sample));
    auto b = CMSampleBufferGetDataBuffer(sample);
    auto bytes = CMBlockBufferGetDataLength(b);
    s.pcm.emplace_back(bytes / sizeof(float));
    CHECK(!CMBlockBufferCopyDataBytes(b, 0, bytes, s.pcm.back().data()));
  }
};
TEST_CASE("storage") {
  PCMStorage ring(4, 1, 1); // Three slots.
  BufferList buffer(1, 4);
  auto *b = buffer.get();
  std::fill_n(static_cast<float *>(b->mBuffers[0].mData), 4, 0.25f);
  auto t = timestamp(1000000000);
  CHECK(ring.write(b, t));
  Descriptor first;
  CHECK(ring.outputQueue.pop(first));
  Descriptor raw;
  CHECK(ring.rawQueue.pop(raw));
  ring.releaseRaw(raw);
  CHECK(ring.acquireMonitor(first));
  ring.releaseOutput(first);
  for (int i = 0; i < 2; ++i) {
    CHECK(ring.write(b, t));
    Descriptor d;
    CHECK(ring.outputQueue.pop(d));
    ring.releaseOutput(d);
    CHECK(ring.rawQueue.pop(d));
    ring.releaseRaw(d);
  }
  CHECK(!ring.write(b, t)); // Output released, but Monitor still reading.
  CHECK(ring.plane(first, 0)[0] == 0.25f);
  ring.releaseMonitor(first);
  for (int i = 0; i < 3; ++i) {
    CHECK(ring.write(b, t));
    Descriptor d;
    CHECK(ring.outputQueue.pop(d));
    ring.releaseOutput(d);
    CHECK(ring.rawQueue.pop(d));
    ring.releaseRaw(d);
  }
  CHECK(!ring.acquireMonitor(first)); // Reused slot rejects stale weak descriptor.
  PCMStorage full(4, 1, 1);
  for (int i = 0; i < 3; ++i)
    CHECK(full.write(b, t));
  CHECK(!full.write(b, t));
  CHECK(full.dropped == 4);
}
TEST_CASE("concurrent storage") {
  PCMStorage ring(16, 1, 64);
  std::atomic<bool> done{false};
  std::thread writer([&] {
    BufferList b(1, 16);
    for (int i = 0; i < 50000; ++i) {
      std::fill_n(static_cast<float *>(b.get()->mBuffers[0].mData), 16, float(i));
      ring.write(b.get(), timestamp(i));
    }
    done = true;
  });
  std::thread reader([&] {
    Descriptor d;
    while (!done || ring.outputQueue.available()) {
      if (ring.outputQueue.pop(d)) {
        auto p = ring.plane(d, 0);
        for (int f = 1; f < 16; ++f)
          CHECK(p[f] == p[0]);
        ring.releaseOutput(d);
      }
    }
  });
  std::thread monitor([&] {
    Descriptor d;
    while (!done || ring.monitorQueue.available()) {
      if (ring.monitorQueue.pop(d) && ring.acquireMonitor(d)) {
        auto p = ring.plane(d, 0);
        for (int f = 1; f < 16; ++f)
          CHECK(p[f] == p[0]);
        ring.releaseMonitor(d);
      }
    }
  });
  std::thread raw([&] {
    Descriptor d;
    while (!done || ring.rawQueue.available()) {
      if (ring.rawQueue.pop(d)) {
        auto p = ring.plane(d, 0);
        for (int f = 1; f < 16; ++f)
          CHECK(p[f] == p[0]);
        ring.releaseRaw(d);
      }
    }
  });
  writer.join();
  reader.join();
  monitor.join();
  raw.join();
}
TEST_CASE("timing") {
  TimestampMapper mapper;
  uint64_t ns;
  AudioTimeStamp t{};
  t.mFlags = kAudioTimeStampSampleTimeValid;
  t.mSampleTime = 0;
  CHECK(!mapper.map(t, 48000, ns));
  t = timestamp(1000000000, 48000);
  CHECK(mapper.map(t, 48000, ns));
  CHECK(ns == 1000000000);
  t.mFlags = kAudioTimeStampSampleTimeValid;
  t.mSampleTime = 96000;
  CHECK(mapper.map(t, 48000, ns));
  CHECK(ns == 2000000000);
  CHECK(!mapper.map(t, 44100, ns));
  Timeline timeline;
  std::vector<float> samples(2048, 0.25), out(2048);
  timeline.insert(samples.data(), 1024, 48000);
  CHECK(timeline.read(out.data(), 1024, 48000));
  CHECK(!timeline.read(out.data(), 1024, 48001));
  timeline.insert(samples.data(), 1024, 48000 + 240000);
  CHECK(!timeline.read(out.data(), 1024, 48000));
}
TEST_CASE("conversion") {
  for (double rate : {44100., 48000.}) {
    Normalizer converter(rate, 1);
    std::vector<float> input(1024, 0.25);
    size_t total = 0;
    for (int n = 0; n < 10; ++n) {
      auto out = converter.convert(input.data(), 1024);
      total += out.size() / 2;
      CHECK(!out.empty());
      for (size_t i = 0; i < out.size(); i += 2)
        CHECK(std::abs(out[i] - out[i + 1]) < 1e-6);
    }
    CHECK(std::abs(double(total) - 10240 * 48000 / rate) < 128);
  }
}
TEST_CASE("engine") {
  auto e = LDTXAudioCreate(false);
  CHECK(e);
  auto a = LDTXAudioAddInput(e, "A", 3, 48000, 1), b = LDTXAudioAddInput(e, "B", 3, 48000, 1);
  CHECK(a == LDTXAudioAddInput(e, "A", 3, 48000, 1));
  auto bus = LDTXAudioCreateBus(e);
  LDTXAudioRoute routes[] = {{a, 2, true}, {b, 2, true}};
  LDTXAudioConfigureBus(e, bus, routes, 2, 2);
  Samples mixed, raw;
  auto token = LDTXAudioSubscribe(e, bus, false, Samples::receive, &mixed);
  LDTXAudioSubscribe(e, a, true, Samples::receive, &raw);
  constexpr uint64_t start = 1000000000;
  LDTXAudioAdvance(e, start);
  BufferList buffer(1, 1024);
  auto *pcm = static_cast<float *>(buffer.get()->mBuffers[0].mData);
  auto t = timestamp(start);
  std::fill_n(pcm, 1024, 0.125f);
  CHECK(LDTXAudioSubmitPCM(e, a, buffer.get(), &t));
  std::fill_n(pcm, 1024, -0.125f);
  CHECK(LDTXAudioSubmitPCM(e, b, buffer.get(), &t));
  LDTXAudioAdvance(e, start + 199999999);
  CHECK(mixed.pts.empty());
  CHECK(raw.pcm.size() == 1);
  CHECK(raw.pcm[0][0] == 0.125);
  LDTXAudioAdvance(e, start + 200000000);
  CHECK(mixed.pts.size() == 1);
  for (auto v : mixed.pcm[0])
    CHECK(v == 0);
  CHECK(LDTXAudioConsumePeak(e, bus, false) == 0);
  CHECK(LDTXAudioConsumePeak(e, a, true) == 0.125);
  routes[1].connected = false;
  LDTXAudioConfigureBus(e, bus, routes, 2, 2);
  t = timestamp(start + 1000000000ull * 1024 / 48000, 1024);
  std::fill_n(pcm, 1024, 0.125f);
  CHECK(LDTXAudioSubmitPCM(e, a, buffer.get(), &t));
  LDTXAudioAdvance(e, start + 200000000 + 1000000000ull * 1024 / 48000);
  CHECK(mixed.pcm.back().back() == 0.5f); // Device x2, then Master x2.
  LDTXAudioAdvance(e, start + 400000000);
  CHECK(mixed.pts.size() == 10); // At most eight catch-up blocks.
  for (size_t i = 1; i < mixed.pts.size(); ++i)
    CHECK(CMTimeCompare(mixed.pts[i - 1], mixed.pts[i]) < 0);
  for (float v : mixed.pcm.back())
    CHECK(v == 0); // Deadline loss mutes the whole missing input block.
  LDTXAudioUnsubscribe(e, token);
  auto count = mixed.pts.size();
  LDTXAudioAdvance(e, start + 500000000);
  CHECK(mixed.pts.size() == count);
  LDTXAudioDestroy(e);
  e = LDTXAudioCreate(false);
  bus = LDTXAudioCreateBus(e);
  Samples silence;
  LDTXAudioSubscribe(e, bus, false, Samples::receive, &silence);
  LDTXAudioAdvance(e, start);
  LDTXAudioAdvance(e, start + 200000000);
  CHECK(silence.pcm.size() == 1);
  for (float v : silence.pcm[0])
    CHECK(v == 0);
  LDTXAudioDestroy(e);
}
TEST_CASE("subscription boundary") {
  auto e = LDTXAudioCreate(false);
  auto bus = LDTXAudioCreateBus(e);
  Samples output;
  auto subscription = LDTXAudioSubscribeAtVideoBoundary(e, bus, Samples::receive, &output);
  constexpr uint64_t start = 2000000000;
  LDTXAudioAdvance(e, start);
  LDTXAudioAdvance(e, start + 200000000);
  CHECK(output.pts.empty());
  LDTXAudioSetVideoBoundary(e, subscription, CMTimeMake(start + 10000000, 1000000000));
  LDTXAudioAdvance(e, start + 222000000);
  CHECK(output.pts.size() == 1);
  auto previous = output.pts.back();
  auto next = LDTXAudioCreateBus(e);
  LDTXAudioSwitchSubscriptionSource(e, subscription, next);
  LDTXAudioAdvance(e, start + 244000000);
  CHECK(output.pts.size() == 2);
  CHECK(CMTimeCompare(CMTimeSubtract(output.pts.back(), previous), CMTimeMake(1024, 48000)) == 0);
  LDTXAudioUnsubscribe(e, subscription);
  LDTXAudioAdvance(e, start + 300000000);
  CHECK(output.pts.size() == 2);
  auto input = LDTXAudioAddInput(e, "reconnect", 3, 48000, 1);
  auto before = LDTXAudioGetStatistics(e, input).generation;
  LDTXAudioRemoveInput(e, input);
  CHECK(input == LDTXAudioAddInput(e, "reconnect", 3, 48000, 1));
  CHECK(LDTXAudioGetStatistics(e, input).generation == before + 1);
  LDTXAudioDestroy(e);
}
TEST_CASE("retained raw") {
  auto e = LDTXAudioCreate(false);
  auto input = LDTXAudioAddInput(e, "retained", 3, 48000, 1);
  CMSampleBufferRef retained = nullptr;
  auto token = LDTXAudioSubscribe(
      e, input, true,
      [](void *context, CMSampleBufferRef sample) {
        auto &saved = *static_cast<CMSampleBufferRef *>(context);
        if (!saved) {
          CFRetain(sample);
          saved = sample;
        }
      },
      &retained);
  BufferList buffer(1, 1024);
  for (uint64_t n = 0; n < 500; ++n) {
    std::fill_n(static_cast<float *>(buffer.get()->mBuffers[0].mData), 1024, float(n));
    auto ns = 1000000000 + n * 1024 * 1000000000 / 48000;
    auto stamp = timestamp(ns, double(n * 1024));
    CHECK(LDTXAudioSubmitPCM(e, input, buffer.get(), &stamp));
    LDTXAudioAdvance(e, ns);
  }
  CHECK(retained);
  LDTXAudioUnsubscribe(e, token);
  LDTXAudioDestroy(e);
  float first = -1;
  CHECK(!CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(retained), 0, sizeof(first), &first));
  CHECK(first == 0);
  CFRelease(retained);
}
TEST_CASE("unsubscribe fence") {
  auto e = LDTXAudioCreate(false);
  auto bus = LDTXAudioCreateBus(e);
  struct State {
    std::atomic<bool> entered{false}, release{false}, cancelled{false};
    std::atomic<unsigned> calls{0};
  } state;
  auto token = LDTXAudioSubscribe(
      e, bus, false,
      [](void *context, CMSampleBufferRef) {
        auto &s = *static_cast<State *>(context);
        ++s.calls;
        s.entered = true;
        while (!s.release.load())
          std::this_thread::yield();
      },
      &state);
  LDTXAudioAdvance(e, 1000000000);
  std::thread advance([&] { LDTXAudioAdvance(e, 1200000000); });
  while (!state.entered.load())
    std::this_thread::yield();
  std::thread cancel([&] {
    LDTXAudioUnsubscribe(e, token);
    state.cancelled = true;
  });
  CHECK(!state.cancelled.load());
  state.release = true;
  advance.join();
  cancel.join();
  CHECK(state.cancelled.load());
  LDTXAudioAdvance(e, 1400000000);
  CHECK(state.calls.load() == 1);
  LDTXAudioDestroy(e);
}
TEST_CASE("backlog fairness") {
  auto e = LDTXAudioCreate(false);
  auto a = LDTXAudioAddInput(e, "backlogged", 3, 48000, 1);
  auto b = LDTXAudioAddInput(e, "healthy", 3, 48000, 1);
  Samples rawA, rawB, mixed;
  LDTXAudioSubscribe(e, a, true, Samples::receive, &rawA);
  LDTXAudioSubscribe(e, b, true, Samples::receive, &rawB);
  auto bus = LDTXAudioCreateBus(e);
  LDTXAudioRoute route{b, 1, true};
  LDTXAudioConfigureBus(e, bus, &route, 1, 1);
  LDTXAudioSubscribe(e, bus, false, Samples::receive, &mixed);
  constexpr uint64_t start = 1000000000;
  LDTXAudioAdvance(e, start);
  BufferList block(1, 1024);
  std::fill_n(static_cast<float *>(block.get()->mBuffers[0].mData), 1024, 0.25f);
  for (unsigned n = 0; n < 100; ++n) {
    auto t = timestamp(start + n * 1024ull * 1000000000 / 48000);
    CHECK(LDTXAudioSubmitPCM(e, a, block.get(), &t));
  }
  auto t = timestamp(start);
  CHECK(LDTXAudioSubmitPCM(e, b, block.get(), &t));
  LDTXAudioAdvance(e, start + 200000000);
  CHECK(rawA.pcm.size() == 32);
  CHECK(rawB.pcm.size() == 1);
  CHECK(mixed.pcm.size() == 1);
  CHECK(mixed.pcm[0].back() == 0.25f);
  LDTXAudioAdvance(e, start + 200000000);
  CHECK(rawA.pcm.size() == 64);
  LDTXAudioDestroy(e);
}
TEST_CASE("input fault isolation") {
  auto e = LDTXAudioCreate(false);
  auto bad = LDTXAudioAddInput(e, "fault", 3, 48000, 1), good = LDTXAudioAddInput(e, "good", 3, 48000, 1);
  auto bus = LDTXAudioCreateBus(e);
  LDTXAudioRoute routes[] = {{bad, 1, true}, {good, 1, true}};
  LDTXAudioConfigureBus(e, bus, routes, 2, 1);
  Samples mix, raw;
  LDTXAudioSubscribe(e, bus, false, Samples::receive, &mix);
  LDTXAudioSubscribe(e, bad, true, Samples::receive, &raw);
  constexpr uint64_t start = 1000000000;
  LDTXAudioAdvance(e, start);
  BufferList data(1, 1024);
  std::fill_n(static_cast<float *>(data.get()->mBuffers[0].mData), 1024, 0.25f);
  AudioTimeStamp invalid{};
  CHECK(LDTXAudioSubmitPCM(e, bad, data.get(), &invalid));
  auto t = timestamp(start);
  CHECK(LDTXAudioSubmitPCM(e, good, data.get(), &t));
  LDTXAudioAdvance(e, start + 200000000);
  CHECK(raw.pcm.empty());
  CHECK(mix.pcm[0].back() == 0.25f);
  CHECK(LDTXAudioGetStatistics(e, bad).invalidTimestamps == 1);
  auto goodGeneration = LDTXAudioGetStatistics(e, good).generation;
  LDTXAudioRemoveInput(e, bad);
  CHECK(bad == LDTXAudioAddInput(e, "fault", 3, 44100, 2));
  CHECK(LDTXAudioGetStatistics(e, bad).generation == 2);
  CHECK(LDTXAudioGetStatistics(e, good).generation == goodGeneration);
  BufferList stereo(2, 512);
  for (unsigned c = 0; c < 2; ++c)
    std::fill_n(static_cast<float *>(stereo.get()->mBuffers[c].mData), 512, 0.125f);
  t = timestamp(start + 300000000);
  CHECK(LDTXAudioSubmitPCM(e, bad, stereo.get(), &t));
  LDTXAudioAdvance(e, start + 300000000);
  CHECK(raw.pcm.size() == 1);
  CHECK(raw.pcm[0].size() == 1024);
  CHECK(CMTimeCompare(raw.pts[0], CMTimeMake(start + 300000000, 1000000000)) == 0);
  LDTXAudioDestroy(e);
}
TEST_CASE("stop fence") {
  auto e = LDTXAudioCreate(false);
  auto bus = LDTXAudioCreateBus(e);
  struct State {
    std::atomic<bool> entered{false}, release{false};
    std::atomic<unsigned> calls{0}, stops{0};
  } state;
  LDTXAudioSubscribe(
      e, bus, false,
      [](void *context, CMSampleBufferRef) {
        auto &s = *static_cast<State *>(context);
        ++s.calls;
        s.entered = true;
        while (!s.release.load())
          std::this_thread::yield();
      },
      &state);
  LDTXAudioAdvance(e, 1000000000);
  // Queue multiple catch-up notifications behind the blocked callback.
  std::thread advance([&] { LDTXAudioAdvance(e, 1400000000); });
  while (!state.entered.load())
    std::this_thread::yield();
  auto completion = [](void *context) { ++static_cast<State *>(context)->stops; };
  LDTXAudioStop(e, completion, &state);
  LDTXAudioStop(e, completion, &state);
  CHECK(state.stops.load() == 0);
  state.release = true;
  advance.join();
  // This synchronous command fences both queued stop completions.
  LDTXAudioAdvance(e, 1400000000);
  CHECK(state.stops.load() == 2);
  CHECK(state.calls.load() == 1);
  LDTXAudioDestroy(e);
}
TEST_CASE("reentrant reconstruction") {
  auto e = LDTXAudioCreate(false);
  auto input = LDTXAudioAddInput(e, "reentrant", 3, 48000, 1);
  auto bus = LDTXAudioCreateBus(e);
  LDTXAudioRoute route{input, 1, true};
  LDTXAudioConfigureBus(e, bus, &route, 1, 1);
  struct State {
    LDTXWorkspaceAudioEngine *engine;
    LDTXAudioID input;
    unsigned first = 0, stale = 0;
  } state{e, input};
  LDTXAudioSubscribe(
      e, bus, false,
      [](void *context, CMSampleBufferRef) {
        auto &s = *static_cast<State *>(context);
        if (++s.first == 1) {
          auto generation = LDTXAudioGetStatistics(s.engine, s.input).generation;
          LDTXAudioRemoveInput(s.engine, s.input);
          CHECK(LDTXAudioAddInput(s.engine, "reentrant", 3, 48000, 1) == s.input);
          CHECK(LDTXAudioGetStatistics(s.engine, s.input).generation == generation);
        }
      },
      &state);
  LDTXAudioSubscribe(
      e, bus, false, [](void *context, CMSampleBufferRef) { ++static_cast<State *>(context)->stale; }, &state);
  constexpr uint64_t start = 1000000000;
  LDTXAudioAdvance(e, start);
  LDTXAudioAdvance(e, start + 200000000);
  CHECK(state.first == 1);
  CHECK(LDTXAudioGetStatistics(e, input).generation == 2);
  CHECK(state.stale == 0); // Pending work copied from the retired generation was discarded.
  LDTXAudioAdvance(e, start + 222000000);
  CHECK(state.first == 2);
  CHECK(state.stale == 1); // Acceptance reopened after reconstruction completed.
  LDTXAudioDestroy(e);
}
TEST_CASE("monitor while output stalled") {
  HALInput input("monitor-test", 3, 48000, 1, false);
  MonitorReader monitor(input);
  BufferList source(1, 512), destination(1, 128);
  auto pcm = static_cast<float *>(source.get()->mBuffers[0].mData);
  // Deliberately leave every raw/mix hold outstanding. Monitor still renders.
  for (unsigned n = 0; n < 500; ++n) {
    std::fill_n(pcm, 512, float(n));
    input.storage->write(source.get(), timestamp(n * 10000000ull));
  }
  CHECK(input.storage->dropped.load() > 0);
  AudioUnitRenderActionFlags flags = 0;
  CHECK(monitor.read(&flags, 128, destination.get()) == noErr);
  CHECK(!(flags & kAudioUnitRenderAction_OutputIsSilence));
  CHECK(static_cast<float *>(destination.get()->mBuffers[0].mData)[0] > 0);
}
