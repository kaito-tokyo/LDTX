// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#include "Internal/AudioTimeline.hpp"
#include "Internal/HALInput.hpp"
#include "Internal/PCMStorage.hpp"
#include "LDTXAudioEngine/WorkspaceAudioEngine.h"
#include <cassert>
#include <iostream>
#include <thread>
using namespace ldtx::audio;
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
    assert(!CMBlockBufferCopyDataBytes(b, 0, bytes, s.pcm.back().data()));
  }
};
static void storageTests() {
  PCMStorage ring(4, 1, 1); // Three slots.
  BufferList buffer(1, 4);
  auto *b = buffer.get();
  std::fill_n(static_cast<float *>(b->mBuffers[0].mData), 4, 0.25f);
  auto t = timestamp(1000000000);
  assert(ring.write(b, t));
  Descriptor first;
  assert(ring.outputQueue.pop(first));
  Descriptor raw;
  assert(ring.rawQueue.pop(raw));
  ring.releaseRaw(raw);
  assert(ring.acquireMonitor(first));
  ring.releaseOutput(first);
  for (int i = 0; i < 2; ++i) {
    assert(ring.write(b, t));
    Descriptor d;
    assert(ring.outputQueue.pop(d));
    ring.releaseOutput(d);
    assert(ring.rawQueue.pop(d));
    ring.releaseRaw(d);
  }
  assert(!ring.write(b, t)); // Output released, but Monitor still reading.
  assert(ring.plane(first, 0)[0] == 0.25f);
  ring.releaseMonitor(first);
  for (int i = 0; i < 3; ++i) {
    assert(ring.write(b, t));
    Descriptor d;
    assert(ring.outputQueue.pop(d));
    ring.releaseOutput(d);
    assert(ring.rawQueue.pop(d));
    ring.releaseRaw(d);
  }
  assert(!ring.acquireMonitor(first)); // Reused slot rejects stale weak descriptor.
  PCMStorage full(4, 1, 1);
  for (int i = 0; i < 3; ++i)
    assert(full.write(b, t));
  assert(!full.write(b, t));
  assert(full.dropped == 4);
}
static void concurrentStorage() {
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
          assert(p[f] == p[0]);
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
          assert(p[f] == p[0]);
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
          assert(p[f] == p[0]);
        ring.releaseRaw(d);
      }
    }
  });
  writer.join();
  reader.join();
  monitor.join();
  raw.join();
}
static void timingTests() {
  TimestampMapper mapper;
  uint64_t ns;
  AudioTimeStamp t{};
  t.mFlags = kAudioTimeStampSampleTimeValid;
  t.mSampleTime = 0;
  assert(!mapper.map(t, 48000, ns));
  t = timestamp(1000000000, 48000);
  assert(mapper.map(t, 48000, ns));
  assert(ns == 1000000000);
  t.mFlags = kAudioTimeStampSampleTimeValid;
  t.mSampleTime = 96000;
  assert(mapper.map(t, 48000, ns) && ns == 2000000000);
  assert(!mapper.map(t, 44100, ns));
  Timeline timeline;
  std::vector<float> samples(2048, 0.25), out(2048);
  timeline.insert(samples.data(), 1024, 48000);
  assert(timeline.read(out.data(), 1024, 48000));
  assert(!timeline.read(out.data(), 1024, 48001));
  timeline.insert(samples.data(), 1024, 48000 + 240000);
  assert(!timeline.read(out.data(), 1024, 48000));
}
static void conversionTests() {
  for (double rate : {44100., 48000.}) {
    Normalizer converter(rate, 1);
    std::vector<float> input(1024, 0.25);
    size_t total = 0;
    for (int n = 0; n < 10; ++n) {
      auto out = converter.convert(input.data(), 1024);
      total += out.size() / 2;
      assert(!out.empty());
      for (size_t i = 0; i < out.size(); i += 2)
        assert(std::abs(out[i] - out[i + 1]) < 1e-6);
    }
    assert(std::abs(double(total) - 10240 * 48000 / rate) < 128);
  }
}
static void engineTests() {
  auto e = LDTXAudioCreate(false);
  assert(e);
  auto a = LDTXAudioAddInput(e, "A", 3, 48000, 1), b = LDTXAudioAddInput(e, "B", 3, 48000, 1);
  assert(a == LDTXAudioAddInput(e, "A", 3, 48000, 1));
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
  assert(LDTXAudioSubmitPCM(e, a, buffer.get(), &t));
  std::fill_n(pcm, 1024, -0.125f);
  assert(LDTXAudioSubmitPCM(e, b, buffer.get(), &t));
  LDTXAudioAdvance(e, start + 199999999);
  assert(mixed.pts.empty());
  assert(raw.pcm.size() == 1 && raw.pcm[0][0] == 0.125);
  LDTXAudioAdvance(e, start + 200000000);
  assert(mixed.pts.size() == 1);
  for (auto v : mixed.pcm[0])
    assert(v == 0);
  assert(LDTXAudioConsumePeak(e, bus, false) == 0);
  assert(LDTXAudioConsumePeak(e, a, true) == 0.125);
  routes[1].connected = false;
  LDTXAudioConfigureBus(e, bus, routes, 2, 2);
  t = timestamp(start + 1000000000ull * 1024 / 48000, 1024);
  std::fill_n(pcm, 1024, 0.125f);
  assert(LDTXAudioSubmitPCM(e, a, buffer.get(), &t));
  LDTXAudioAdvance(e, start + 200000000 + 1000000000ull * 1024 / 48000);
  assert(mixed.pcm.back().back() == 0.5f); // Device x2, then Master x2.
  LDTXAudioAdvance(e, start + 400000000);
  assert(mixed.pts.size() == 10); // At most eight catch-up blocks.
  for (size_t i = 1; i < mixed.pts.size(); ++i)
    assert(CMTimeCompare(mixed.pts[i - 1], mixed.pts[i]) < 0);
  for (float v : mixed.pcm.back())
    assert(v == 0); // Deadline loss mutes the whole missing input block.
  LDTXAudioUnsubscribe(e, token);
  auto count = mixed.pts.size();
  LDTXAudioAdvance(e, start + 500000000);
  assert(mixed.pts.size() == count);
  LDTXAudioDestroy(e);
  e = LDTXAudioCreate(false);
  bus = LDTXAudioCreateBus(e);
  Samples silence;
  LDTXAudioSubscribe(e, bus, false, Samples::receive, &silence);
  LDTXAudioAdvance(e, start);
  LDTXAudioAdvance(e, start + 200000000);
  assert(silence.pcm.size() == 1);
  for (float v : silence.pcm[0])
    assert(v == 0);
  LDTXAudioDestroy(e);
}
static void subscriptionBoundaryTests() {
  auto e = LDTXAudioCreate(false);
  auto bus = LDTXAudioCreateBus(e);
  Samples output;
  auto subscription = LDTXAudioSubscribeAtVideoBoundary(e, bus, Samples::receive, &output);
  constexpr uint64_t start = 2000000000;
  LDTXAudioAdvance(e, start);
  LDTXAudioAdvance(e, start + 200000000);
  assert(output.pts.empty());
  LDTXAudioSetVideoBoundary(e, subscription, CMTimeMake(start + 10000000, 1000000000));
  LDTXAudioAdvance(e, start + 222000000);
  assert(output.pts.size() == 1);
  auto previous = output.pts.back();
  auto next = LDTXAudioCreateBus(e);
  LDTXAudioSwitchSubscriptionSource(e, subscription, next);
  LDTXAudioAdvance(e, start + 244000000);
  assert(output.pts.size() == 2);
  assert(CMTimeCompare(CMTimeSubtract(output.pts.back(), previous), CMTimeMake(1024, 48000)) == 0);
  LDTXAudioUnsubscribe(e, subscription);
  LDTXAudioAdvance(e, start + 300000000);
  assert(output.pts.size() == 2);
  auto input = LDTXAudioAddInput(e, "reconnect", 3, 48000, 1);
  auto before = LDTXAudioGetStatistics(e, input).generation;
  LDTXAudioRemoveInput(e, input);
  assert(input == LDTXAudioAddInput(e, "reconnect", 3, 48000, 1));
  assert(LDTXAudioGetStatistics(e, input).generation == before + 1);
  LDTXAudioDestroy(e);
}
static void retainedRawTests() {
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
    assert(LDTXAudioSubmitPCM(e, input, buffer.get(), &stamp));
    LDTXAudioAdvance(e, ns);
  }
  assert(retained);
  LDTXAudioUnsubscribe(e, token);
  LDTXAudioDestroy(e);
  float first = -1;
  assert(!CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(retained), 0, sizeof(first), &first));
  assert(first == 0);
  CFRelease(retained);
}
static void unsubscribeFenceTests() {
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
  assert(!state.cancelled.load());
  state.release = true;
  advance.join();
  cancel.join();
  assert(state.cancelled.load());
  LDTXAudioAdvance(e, 1400000000);
  assert(state.calls.load() == 1);
  LDTXAudioDestroy(e);
}
static void backlogFairnessTests() {
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
    assert(LDTXAudioSubmitPCM(e, a, block.get(), &t));
  }
  auto t = timestamp(start);
  assert(LDTXAudioSubmitPCM(e, b, block.get(), &t));
  LDTXAudioAdvance(e, start + 200000000);
  assert(rawA.pcm.size() == 32);
  assert(rawB.pcm.size() == 1);
  assert(mixed.pcm.size() == 1);
  assert(mixed.pcm[0].back() == 0.25f);
  LDTXAudioAdvance(e, start + 200000000);
  assert(rawA.pcm.size() == 64);
  LDTXAudioDestroy(e);
}
static void inputFaultIsolationTests() {
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
  assert(LDTXAudioSubmitPCM(e, bad, data.get(), &invalid));
  auto t = timestamp(start);
  assert(LDTXAudioSubmitPCM(e, good, data.get(), &t));
  LDTXAudioAdvance(e, start + 200000000);
  assert(raw.pcm.empty());
  assert(mix.pcm[0].back() == 0.25f);
  assert(LDTXAudioGetStatistics(e, bad).invalidTimestamps == 1);
  auto goodGeneration = LDTXAudioGetStatistics(e, good).generation;
  LDTXAudioRemoveInput(e, bad);
  assert(bad == LDTXAudioAddInput(e, "fault", 3, 44100, 2));
  assert(LDTXAudioGetStatistics(e, bad).generation == 2);
  assert(LDTXAudioGetStatistics(e, good).generation == goodGeneration);
  BufferList stereo(2, 512);
  for (unsigned c = 0; c < 2; ++c)
    std::fill_n(static_cast<float *>(stereo.get()->mBuffers[c].mData), 512, 0.125f);
  t = timestamp(start + 300000000);
  assert(LDTXAudioSubmitPCM(e, bad, stereo.get(), &t));
  LDTXAudioAdvance(e, start + 300000000);
  assert(raw.pcm.size() == 1);
  assert(raw.pcm[0].size() == 1024);
  assert(CMTimeCompare(raw.pts[0], CMTimeMake(start + 300000000, 1000000000)) == 0);
  LDTXAudioDestroy(e);
}
static void stopFenceTests() {
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
  std::thread advance([&] { LDTXAudioAdvance(e, 1200000000); });
  while (!state.entered.load())
    std::this_thread::yield();
  auto completion = [](void *context) { ++static_cast<State *>(context)->stops; };
  LDTXAudioStop(e, completion, &state);
  LDTXAudioStop(e, completion, &state);
  assert(state.stops.load() == 0);
  state.release = true;
  advance.join();
  // This synchronous command fences both queued stop completions.
  LDTXAudioAdvance(e, 1400000000);
  assert(state.stops.load() == 2);
  assert(state.calls.load() == 1);
  LDTXAudioDestroy(e);
}
static void monitorWhileOutputStalledTests() {
  HALInput input("monitor-test", 3, 48000, 1, false);
  MonitorReader monitor(input);
  BufferList source(1, 512), destination(1, 128);
  auto pcm = static_cast<float *>(source.get()->mBuffers[0].mData);
  // Deliberately leave every raw/mix hold outstanding. Monitor still renders.
  for (unsigned n = 0; n < 500; ++n) {
    std::fill_n(pcm, 512, float(n));
    input.storage->write(source.get(), timestamp(n * 10000000ull));
  }
  assert(input.storage->dropped.load() > 0);
  AudioUnitRenderActionFlags flags = 0;
  assert(monitor.read(&flags, 128, destination.get()) == noErr);
  assert(!(flags & kAudioUnitRenderAction_OutputIsSilence));
  assert(static_cast<float *>(destination.get()->mBuffers[0].mData)[0] > 0);
}
int main() {
  try {
    storageTests();
    concurrentStorage();
    timingTests();
    std::cerr << "conversion\n";
    conversionTests();
    std::cerr << "engine\n";
    engineTests();
    subscriptionBoundaryTests();
    retainedRawTests();
    unsubscribeFenceTests();
    backlogFairnessTests();
    inputFaultIsolationTests();
    stopFenceTests();
    monitorWhileOutputStalledTests();
    std::cout << "Native audio tests passed\n";
  } catch (const StatusError &e) {
    std::cerr << "status=" << e.status << "\n";
    return 1;
  }
}
