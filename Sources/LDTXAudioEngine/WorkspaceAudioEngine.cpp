// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#include "LDTXAudioEngine/WorkspaceAudioEngine.h"
#include "Internal/HALInput.hpp"
#include "LDTXAudioEngine/AudioMixEngine.hpp"
#include <condition_variable>
#include <deque>
#include <functional>
#include <future>
#include <map>
#include <mutex>
#include <os/log.h>
#include <set>
#include <thread>
using namespace ldtx::audio;
namespace {
struct Bus {
  std::vector<LDTXAudioRoute> routes;
  std::unique_ptr<LDTXAudioMixEngine> gains;
  LDTXAudioMixEngine master{1};
  float peak = 0;
  uint64_t start = 0, deadline = 0, rendered = 0;
  Bus() = default;
};
struct Subscription {
  LDTXAudioID source;
  bool raw;
  LDTXAudioSampleHandler handler;
  void *context;
  bool active = true;
  bool awaitsVideo = false;
  CMTime boundary = kCMTimeInvalid, lastEnd = kCMTimeInvalid;
};
struct Notice {
  std::shared_ptr<Subscription> subscription;
  std::shared_ptr<opaqueCMSampleBuffer> sample;
  LDTXAudioID source;
};
struct InputRecord {
  std::string uid;
  uint32_t kind;
  double rate;
  uint32_t channels;
  uint64_t generation = 0;
  std::unique_ptr<HALInput> input;
  bool enabled = true;
};
struct MonitorGraph {
  // Consumer units are disposed before their source callback contexts.
  std::vector<std::unique_ptr<MonitorReader>> readers;
  std::vector<LDTXAudioID> order;
  std::vector<std::unique_ptr<Unit>> converters;
  std::unique_ptr<Unit> mixer, output;
  uint32_t frames = 0;
  ~MonitorGraph() {
    if (output)
      output->stop();
    for (auto &reader : readers)
      reader->waitForRender();
    output.reset();
    mixer.reset();
    converters.clear();
    readers.clear();
  }
};
} // namespace
struct LDTXWorkspaceAudioEngine {
  bool hardware, stopping = false, quitting = false;
  std::thread worker;
  std::mutex mutex;
  std::condition_variable wake;
  std::deque<std::function<void()>> commands;
  std::map<LDTXAudioID, InputRecord> inputs;
  std::map<LDTXAudioID, Bus> buses;
  std::map<LDTXAudioID, std::shared_ptr<Subscription>> subscriptions;
  std::unique_ptr<MonitorGraph> monitor;
  std::vector<Notice> notices;
  std::string outputUID;
  std::vector<LDTXAudioRoute> monitorRoutes;
  float monitorMaster = 1;
  LDTXAudioID nextID = 1;
  LDTXAudioErrorHandler errorHandler = nullptr;
  void *errorContext = nullptr;
  uint64_t retryAt = 0, mixAnchor = 0;
  os_log_t logger = os_log_create("tokyo.kaito.ldtx", "AudioEngine");
  std::atomic<bool> hardwareChanged{false};
  struct Watch {
    AudioObjectID id;
    AudioObjectPropertyAddress address;
  };
  std::vector<Watch> watches;
  explicit LDTXWorkspaceAudioEngine(bool h) : hardware(h) {
    worker = std::thread([this] { run(); });
  }
  ~LDTXWorkspaceAudioEngine() {
    sync([this] { shutdown(); });
    {
      std::lock_guard<std::mutex> lock(mutex);
      quitting = true;
    }
    wake.notify_one();
    worker.join();
  }
  void post(std::function<void()> f) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      commands.push_back(std::move(f));
    }
    wake.notify_one();
  }
  template <class F> auto sync(F f) -> decltype(f()) {
    if (std::this_thread::get_id() == worker.get_id())
      return f();
    auto task = std::make_shared<std::packaged_task<decltype(f())()>>(std::move(f));
    auto result = task->get_future();
    post([task] { (*task)(); });
    return result.get();
  }
  void run() {
    for (;;) {
      std::deque<std::function<void()>> batch;
      {
        std::unique_lock<std::mutex> lock(mutex);
        wake.wait_for(lock, std::chrono::milliseconds(2), [this] { return quitting || !commands.empty(); });
        if (quitting)
          return;
        batch.swap(commands);
      }
      for (auto &f : batch)
        f();
      if (hardware && !stopping) {
        auto now = nowNanos();
        if (hardwareChanged.exchange(false) || now >= retryAt) {
          refreshHardware();
          retryAt = now + 1000000000;
        }
        tick(now);
      }
    }
  }
  void report(const std::string &source, OSStatus status) {
    if (errorHandler)
      errorHandler(errorContext, source.c_str(), status);
  }
  static OSStatus changed(AudioObjectID, UInt32, const AudioObjectPropertyAddress *, void *context) {
    static_cast<LDTXWorkspaceAudioEngine *>(context)->hardwareChanged.store(true, std::memory_order_release);
    return noErr;
  }
  void clearWatches() {
    for (auto &w : watches)
      AudioObjectRemovePropertyListener(w.id, &w.address, changed, this);
    watches.clear();
  }
  void watch(AudioObjectID id, AudioObjectPropertySelector selector,
             AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    AudioObjectPropertyAddress a{selector, scope, kAudioObjectPropertyElementMain};
    if (!AudioObjectAddPropertyListener(id, &a, changed, this))
      watches.push_back({id, a});
  }
  void rebuildWatches() {
    clearWatches();
    if (!hardware)
      return;
    watch(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
    for (auto &[id, r] : inputs)
      if (r.input && r.input->device) {
        watch(r.input->device, kAudioDevicePropertyDeviceIsAlive);
        watch(r.input->device, kAudioDevicePropertyNominalSampleRate);
        watch(r.input->device, kAudioDevicePropertyBufferFrameSize);
        watch(r.input->device, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput);
      }
    if (!outputUID.empty())
      try {
        auto id = deviceForUID(outputUID.c_str());
        watch(id, kAudioDevicePropertyDeviceIsAlive);
        watch(id, kAudioDevicePropertyNominalSampleRate);
        watch(id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput);
      } catch (...) {
      }
  }
  void openInput(InputRecord &r) {
    try {
      r.input = std::make_unique<HALInput>(r.uid, r.kind, r.rate, r.channels, hardware, r.generation + 1);
      r.input->generation = ++r.generation;
      report(r.uid, 0);
      os_log_with_type(logger, OS_LOG_TYPE_DEFAULT, "LDTX AUHAL input started generation=%llu frames=%u", r.generation,
                       r.input->quantum);
    } catch (const StatusError &e) {
      r.input.reset();
      report(r.uid, e.status);
    } catch (...) {
      r.input.reset();
      report(r.uid, memFullErr);
    }
  }
  void refreshHardware() {
    bool changedInputs = false;
    for (auto &[id, r] : inputs) {
      if (r.kind != 0 || !r.enabled)
        continue;
      bool valid = false;
      if (r.input)
        try {
          auto device = deviceForUID(r.uid.c_str());
          AudioObjectPropertyAddress a{kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
          Float64 rate = 0;
          UInt32 size = sizeof(rate);
          check(AudioObjectGetPropertyData(device, &a, 0, nullptr, &size, &rate));
          AudioObjectPropertyAddress streams{kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput,
                                             kAudioObjectPropertyElementMain};
          UInt32 bytes = 0;
          check(AudioObjectGetPropertyDataSize(device, &streams, 0, nullptr, &bytes));
          std::vector<uint64_t> memory((bytes + 7) / 8);
          auto *list = reinterpret_cast<AudioBufferList *>(memory.data());
          check(AudioObjectGetPropertyData(device, &streams, 0, nullptr, &bytes, list));
          uint32_t channels = 0;
          for (UInt32 c = 0; c < list->mNumberBuffers; ++c)
            channels += list->mBuffers[c].mNumberChannels;
          valid = device == r.input->device && rate == r.input->rate && channels == r.input->channels &&
                  deviceFrames(device) == r.input->quantum;
        } catch (...) {
        }
      if (!valid) {
        monitor.reset();
        r.input.reset();
        openInput(r);
        changedInputs = true;
      }
    }
    bool changedOutput = false;
    if (monitor && !outputUID.empty())
      try {
        auto d = deviceForUID(outputUID.c_str());
        auto actual =
            monitor->output->get<AudioDeviceID>(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0);
        auto f = monitor->output->get<AudioStreamBasicDescription>(kAudioUnitProperty_StreamFormat,
                                                                   kAudioUnitScope_Output, 0);
        auto client = monitor->output->get<AudioStreamBasicDescription>(kAudioUnitProperty_StreamFormat,
                                                                        kAudioUnitScope_Input, 0);
        changedOutput = d != actual || f.mSampleRate != client.mSampleRate;
      } catch (...) {
        changedOutput = true;
      }
    if (changedInputs || changedOutput || (!monitor && !outputUID.empty())) {
      rebuildMonitor();
      rebuildWatches();
    }
  }
  void applyMonitorGains() {
    if (!monitor)
      return;
    for (size_t bus = 0; bus < monitor->order.size(); ++bus) {
      float gain = 0;
      for (auto &route : monitorRoutes)
        if (route.input == monitor->order[bus] && route.connected)
          gain += route.gain;
      AudioUnitSetParameter(monitor->mixer->value, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, UInt32(bus),
                            gain, 0);
    }
    AudioUnitSetParameter(monitor->mixer->value, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0,
                          monitorMaster, 0);
  }
  void rebuildMonitor() {
    monitor.reset();
    if (!hardware || outputUID.empty()) {
      report("Monitor", 0);
      return;
    }
    try {
      auto graph = std::make_unique<MonitorGraph>();
      std::set<LDTXAudioID> used;
      for (auto &route : monitorRoutes)
        if (inputs.count(route.input) && inputs.at(route.input).input)
          used.insert(route.input);
      if (used.empty())
        return;
      auto device = deviceForUID(outputUID.c_str());
      graph->output = std::make_unique<Unit>(kAudioUnitType_Output, kAudioUnitSubType_HALOutput);
      auto &out = *graph->output;
      out.set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(0));
      out.set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(1));
      out.set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device);
      out.set(kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, UInt32(128));
      graph->frames = out.get<UInt32>(kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0);
      auto hw = out.get<AudioStreamBasicDescription>(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
      auto format = pcmFormat(hw.mSampleRate, std::min(2u, hw.mChannelsPerFrame));
      if (format.mSampleRate <= 0 || !format.mChannelsPerFrame)
        throw StatusError(kAudioUnitErr_FormatNotSupported);
      out.set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, format);
      out.set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, UInt32(4096));
      graph->mixer = std::make_unique<Unit>(kAudioUnitType_Mixer, kAudioUnitSubType_MultiChannelMixer);
      auto &mixer = *graph->mixer;
      mixer.set(kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, UInt32(used.size()));
      mixer.set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, UInt32(4096));
      mixer.set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, format);
      for (auto id : used) {
        auto &input = *inputs.at(id).input;
        auto reader = std::make_unique<MonitorReader>(input);
        auto converter = std::make_unique<Unit>(kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
        converter->set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, UInt32(4096));
        converter->set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                       pcmFormat(input.rate, input.channels));
        converter->set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, format);
        AURenderCallbackStruct callback{MonitorReader::render, reader.get()};
        converter->set(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, callback);
        auto bus = UInt32(graph->order.size());
        mixer.set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, bus, format);
        converter->connect(mixer, bus);
        converter->initialize();
        graph->order.push_back(id);
        graph->readers.push_back(std::move(reader));
        graph->converters.push_back(std::move(converter));
      }
      mixer.connect(out);
      mixer.initialize();
      out.initialize();
      monitor = std::move(graph);
      applyMonitorGains();
      monitor->output->start();
      report("Monitor", 0);
      os_log_with_type(logger, OS_LOG_TYPE_DEFAULT, "LDTX AUHAL monitor outputFrames=%u", monitor->frames);
    } catch (const StatusError &e) {
      monitor.reset();
      report("Monitor", e.status);
    } catch (...) {
      monitor.reset();
      report("Monitor", memFullErr);
    }
  }
  void publish(LDTXAudioID id, bool raw, CMSampleBufferRef sample) {
    if (!sample) {
      report("SampleBuffer", memFullErr);
      return;
    }
    std::shared_ptr<opaqueCMSampleBuffer> owned(sample, [](CMSampleBufferRef value) { CFRelease(value); });
    for (auto &[key, s] : subscriptions)
      if (s->source == id && s->raw == raw)
        notices.push_back({s, owned, id});
  }
  void deliver() {
    auto batch = std::move(notices);
    notices.clear();
    for (auto &notice : batch) {
      auto &s = *notice.subscription;
      if (!s.active || s.source != notice.source || s.awaitsVideo)
        continue;
      auto pts = CMSampleBufferGetPresentationTimeStamp(notice.sample.get());
      if (CMTIME_IS_NUMERIC(s.boundary) && CMTimeCompare(pts, s.boundary) < 0)
        continue;
      if (CMTIME_IS_NUMERIC(s.lastEnd) && CMTimeCompare(pts, s.lastEnd) < 0)
        continue;
      if (!s.raw)
        s.lastEnd = CMTimeAdd(pts, CMSampleBufferGetDuration(notice.sample.get()));
      s.handler(s.context, notice.sample.get());
    }
  }
  bool hasRaw(LDTXAudioID id) const {
    for (auto &[key, s] : subscriptions)
      if (s->source == id && s->raw)
        return true;
    return false;
  }
  void drain() {
    for (auto &[id, r] : inputs)
      if (r.input) {
        auto &input = *r.input;
        Descriptor d;
        // Snapshot and cap each input's work. A live producer must not keep
        // this worker draining forever or grow the pending notice batch.
        constexpr uint64_t maximumDrainBlocks = 32;
        const auto rawBudget = std::min(maximumDrainBlocks, input.storage->rawQueue.available());
        for (uint64_t n = 0; n < rawBudget && input.storage->rawQueue.pop(d); ++n) {
          uint64_t ns = 0;
          if (hasRaw(id) && input.timestamps.map(d.time, input.rate, ns)) {
            std::vector<float> raw(size_t(d.frames) * input.channels);
            for (uint32_t c = 0; c < input.channels; ++c)
              for (uint32_t f = 0; f < d.frames; ++f)
                raw[size_t(f) * input.channels + c] = input.storage->plane(d, c)[f];
            input.storage->releaseRaw(d);
            publish(id, true, makeSample(raw.data(), d.frames, input.rate, input.channels, CMTimeMake(ns, 1000000000)));
          } else
            input.storage->releaseRaw(d);
        }
        const auto mixBudget = std::min(maximumDrainBlocks, input.storage->outputQueue.available());
        for (uint64_t n = 0; n < mixBudget && input.storage->outputQueue.pop(d); ++n) {
          uint64_t ns = 0;
          if (!input.timestamps.map(d.time, input.rate, ns)) {
            ++input.invalid;
            input.storage->releaseOutput(d);
            continue;
          }
          std::vector<float> raw(size_t(d.frames) * input.channels);
          for (uint32_t c = 0; c < input.channels; ++c)
            for (uint32_t f = 0; f < d.frames; ++f) {
              auto v = input.storage->plane(d, c)[f];
              raw[size_t(f) * input.channels + c] = v;
              if (std::isfinite(v))
                input.peak = std::max(input.peak, std::abs(v));
            }
          input.storage->releaseOutput(d);
          try {
            if (input.previousSourceEnd &&
                std::llabs(int64_t(ns) - int64_t(input.previousSourceEnd)) > int64_t(std::ceil(1e9 / input.rate)))
              input.normalizer->reset();
            auto normalized = input.normalizer->convert(raw.data(), d.frames);
            auto placement = Timeline::frameAt(ns);
            if (input.normalizedEnd >= 0 && std::llabs(placement - input.normalizedEnd) <= 1 &&
                std::llabs(int64_t(ns) - int64_t(input.previousSourceEnd)) <= int64_t(std::ceil(1e9 / input.rate)))
              placement = input.normalizedEnd;
            input.timeline.insert(normalized.data(), uint32_t(normalized.size() / 2), placement);
            input.normalizedEnd = placement + int64_t(normalized.size() / 2);
            input.previousSourceEnd = ns + uint64_t(d.frames * 1e9 / input.rate);

          } catch (const StatusError &e) {
            report(input.uid, e.status);
          }
        }
      }
  }
  void tick(uint64_t now) {
    if (stopping)
      return;
    if (!mixAnchor)
      mixAnchor = now;
    for (auto &[id, r] : inputs)
      if (r.input && (r.kind == 1 || r.kind == 2)) {
        auto &input = *r.input;
        if (!input.generatedStart)
          input.generatedStart = now;
        for (unsigned n = 0; n < 8; ++n) {
          auto ns = input.generatedStart + input.generatedFrames * 1000000000 / 48000;
          if (ns > now)
            break;
          BufferList data(2, 1024);
          for (uint32_t f = 0; f < 1024; ++f) {
            double t = double(input.generatedFrames + f) / 48000;
            float value = r.kind == 1
                              ? float(0.25 * std::sin(2 * M_PI * (220 * t + 110 * std::fmod(t, 10) * std::fmod(t, 10))))
                              : 0;
            for (unsigned c = 0; c < 2; ++c)
              static_cast<float *>(data.get()->mBuffers[c].mData)[f] = value;
          }
          mach_timebase_info_data_t scale;
          mach_timebase_info(&scale);
          AudioTimeStamp stamp{};
          stamp.mHostTime = uint64_t(__uint128_t(ns) * scale.denom / scale.numer);
          stamp.mSampleTime = double(input.generatedFrames);
          stamp.mFlags = kAudioTimeStampHostTimeValid | kAudioTimeStampSampleTimeValid;
          input.storage->write(data.get(), stamp);
          input.generatedFrames += 1024;
        }
      }
    drain();
    for (auto &[id, b] : buses) {
      if (!b.deadline) {
        b.start = mixAnchor;
        if (now > mixAnchor + 200000000)
          b.rendered = uint64_t((__uint128_t(now - mixAnchor - 200000000) * 48000) / 1000000000) / 1024 * 1024;
        b.deadline = b.start + 200000000 + uint64_t(__uint128_t(b.rendered) * 1000000000 / 48000);
      }
      for (unsigned catchup = 0; catchup < 8 && now >= b.deadline; ++catchup) {
        constexpr uint32_t frames = 1024;
        const int64_t start = Timeline::frameAt(b.start) + int64_t(b.rendered);
        std::vector<float> mixed(frames * 2), source(frames * 2);
        for (size_t c = 0; c < b.routes.size(); ++c) {
          auto &route = b.routes[c];
          auto found = inputs.find(route.input);
          if (found == inputs.end() || !found->second.input)
            continue;
          auto &input = *found->second.input;
          bool valid = input.timeline.read(source.data(), frames, start);
          if (valid && b.gains)
            b.gains->mixInterleavedFloat32(int32_t(c), source.data(), mixed.data(), frames, 2, false);
        }
        b.master.applyGainInterleavedFloat32(0, mixed.data(), frames, 2);
        for (float v : mixed)
          if (std::isfinite(v))
            b.peak = std::max(b.peak, std::abs(v));
        auto pts = CMTimeMake(start, 48000);
        b.rendered += frames;
        b.deadline = b.start + 200000000 + uint64_t(__uint128_t(b.rendered) * 1000000000 / 48000);
        publish(id, false, makeSample(mixed.data(), frames, 48000, 2, pts));
      }
    }
    deliver();
  }
  void shutdown() {
    stopping = true;
    clearWatches();
    monitor.reset();
    for (auto &[id, r] : inputs)
      if (r.input)
        r.input->stop();
    for (auto &[id, s] : subscriptions)
      s->active = false;
    subscriptions.clear();
    notices.clear();
    buses.clear();
    inputs.clear();
    monitorRoutes.clear();
    mixAnchor = 0;
  }
};
extern "C" {
LDTXWorkspaceAudioEngine *LDTXAudioCreate(bool hardware) {
  try {
    return new LDTXWorkspaceAudioEngine(hardware);
  } catch (...) {
    return nullptr;
  }
}
void LDTXAudioDestroy(LDTXWorkspaceAudioEngine *e) {
  if (e && std::this_thread::get_id() == e->worker.get_id()) {
    // A subscriber can release its last owner while being notified. Join the
    // worker from a separate control thread after this notification returns.
    std::thread([e] { delete e; }).detach();
  } else
    delete e;
}
void LDTXAudioSetErrorHandler(LDTXWorkspaceAudioEngine *e, LDTXAudioErrorHandler h, void *c) {
  e->sync([=] {
    e->errorHandler = h;
    e->errorContext = c;
  });
}
LDTXAudioID LDTXAudioAddInput(LDTXWorkspaceAudioEngine *e, const char *uid, uint32_t kind, double rate,
                              uint32_t channels) {
  std::string name = uid ? uid : "";
  return e->sync([=] {
    e->stopping = false;
    for (auto &[id, r] : e->inputs)
      if (r.uid == name && r.kind == kind) {
        if (!r.enabled) {
          r.enabled = true;
          r.rate = rate;
          r.channels = channels;
          e->openInput(r);
          e->rebuildWatches();
        }
        return id;
      }
    auto id = e->nextID++;
    auto [it, inserted] = e->inputs.emplace(id, InputRecord{name, kind, rate, channels, 0, nullptr});
    e->openInput(it->second);
    e->rebuildWatches();
    return id;
  });
}
void LDTXAudioRemoveInput(LDTXWorkspaceAudioEngine *e, LDTXAudioID id) {
  e->sync([=] {
    e->monitor.reset();
    e->clearWatches();
    auto it = e->inputs.find(id);
    if (it != e->inputs.end()) {
      it->second.enabled = false;
      it->second.input.reset();
    }
    e->rebuildMonitor();
    e->rebuildWatches();
  });
}
LDTXAudioID LDTXAudioCreateBus(LDTXWorkspaceAudioEngine *e) {
  return e->sync([=] {
    e->stopping = false;
    auto id = e->nextID++;
    e->buses.try_emplace(id);
    return id;
  });
}
void LDTXAudioConfigureBus(LDTXWorkspaceAudioEngine *e, LDTXAudioID id, const LDTXAudioRoute *routes, uint32_t count,
                           float master) {
  std::vector<LDTXAudioRoute> copy;
  if (count)
    copy.assign(routes, routes + count);
  e->sync([=] {
    auto it = e->buses.find(id);
    if (it == e->buses.end())
      return;
    auto &b = it->second;
    bool topology = b.routes.size() != copy.size();
    if (!topology)
      for (size_t i = 0; i < copy.size(); ++i)
        topology |= b.routes[i].input != copy[i].input;
    b.routes = copy;
    if (topology || !b.gains)
      b.gains = std::make_unique<LDTXAudioMixEngine>(std::max(1, int(count)));
    for (size_t i = 0; i < copy.size(); ++i)
      b.gains->setChannelGain(int(i), copy[i].connected ? copy[i].gain : 0);
    b.master.setChannelGain(0, std::isfinite(master) ? master : 0);
  });
}
void LDTXAudioRemoveBus(LDTXWorkspaceAudioEngine *e, LDTXAudioID id) {
  e->sync([=] { e->buses.erase(id); });
}
void LDTXAudioConfigureMonitor(LDTXWorkspaceAudioEngine *e, const char *uid, const LDTXAudioRoute *routes,
                               uint32_t count, float master) {
  std::string name = uid ? uid : "";
  std::vector<LDTXAudioRoute> copy;
  if (count)
    copy.assign(routes, routes + count);
  e->sync([=] {
    bool topology = e->outputUID != name || copy.size() != e->monitorRoutes.size();
    if (!topology)
      for (size_t i = 0; i < copy.size(); ++i)
        topology |= copy[i].input != e->monitorRoutes[i].input;
    e->outputUID = name;
    e->monitorRoutes = copy;
    e->monitorMaster = std::isfinite(master) ? master : 0;
    if (topology || !e->monitor) {
      e->rebuildMonitor();
      e->rebuildWatches();
    } else
      e->applyMonitorGains();
  });
}
LDTXAudioID LDTXAudioSubscribe(LDTXWorkspaceAudioEngine *e, LDTXAudioID source, bool raw, LDTXAudioSampleHandler h,
                               void *c) {
  return e->sync([=] {
    auto id = e->nextID++;
    e->subscriptions[id] = std::make_shared<Subscription>(Subscription{source, raw, h, c, true});
    return id;
  });
}
LDTXAudioID LDTXAudioSubscribeAtVideoBoundary(LDTXWorkspaceAudioEngine *e, LDTXAudioID source, LDTXAudioSampleHandler h,
                                              void *c) {
  return e->sync([=] {
    auto id = e->nextID++;
    auto s = std::make_shared<Subscription>(Subscription{source, false, h, c, true});
    s->awaitsVideo = true;
    e->subscriptions[id] = s;
    return id;
  });
}
void LDTXAudioSetVideoBoundary(LDTXWorkspaceAudioEngine *e, LDTXAudioID id, CMTime pts) {
  e->sync([=] {
    auto it = e->subscriptions.find(id);
    if (it == e->subscriptions.end() || !CMTIME_IS_NUMERIC(pts))
      return;
    auto &s = *it->second;
    if (s.awaitsVideo) {
      s.boundary = pts;
      s.awaitsVideo = false;
    }
  });
}
void LDTXAudioSwitchSubscriptionSource(LDTXWorkspaceAudioEngine *e, LDTXAudioID id, LDTXAudioID source) {
  e->sync([=] {
    auto it = e->subscriptions.find(id);
    if (it != e->subscriptions.end())
      it->second->source = source;
  });
}
void LDTXAudioUnsubscribe(LDTXWorkspaceAudioEngine *e, LDTXAudioID id) {
  e->sync([=] {
    auto it = e->subscriptions.find(id);
    if (it != e->subscriptions.end()) {
      it->second->active = false;
      e->subscriptions.erase(it);
    }
  });
}
float LDTXAudioConsumePeak(LDTXWorkspaceAudioEngine *e, LDTXAudioID id, bool raw) {
  return e->sync([=] {
    float *p = nullptr;
    if (raw) {
      auto it = e->inputs.find(id);
      if (it != e->inputs.end() && it->second.input)
        p = &it->second.input->peak;
    } else {
      auto it = e->buses.find(id);
      if (it != e->buses.end())
        p = &it->second.peak;
    }
    float value = p ? *p : 0;
    if (p)
      *p = 0;
    return value;
  });
}
LDTXAudioStatistics LDTXAudioGetStatistics(LDTXWorkspaceAudioEngine *e, LDTXAudioID id) {
  return e->sync([=] {
    LDTXAudioStatistics s{};
    auto it = e->inputs.find(id);
    if (it != e->inputs.end() && it->second.input) {
      auto &i = *it->second.input;
      s.receivedFrames = i.storage->received;
      s.droppedFrames = i.storage->dropped;
      s.invalidTimestamps = i.invalid;
      s.renderErrors = i.errors;
      s.generation = i.generation;
      s.inputBufferFrames = i.quantum;
    }
    s.outputBufferFrames = e->monitor ? e->monitor->frames : 0;
    return s;
  });
}
void LDTXAudioStop(LDTXWorkspaceAudioEngine *e, LDTXAudioCompletion h, void *c) {
  e->post([=] {
    e->shutdown();
    if (h)
      h(c);
  });
}
bool LDTXAudioSubmitPCM(LDTXWorkspaceAudioEngine *e, LDTXAudioID id, const AudioBufferList *b,
                        const AudioTimeStamp *t) {
  // Only the deterministic hardware-disabled harness may inject PCM. No concurrent topology mutation.
  if (e->hardware || !t)
    return false;
  auto it = e->inputs.find(id);
  return it != e->inputs.end() && it->second.input && it->second.input->storage->write(b, *t);
}
void LDTXAudioAdvance(LDTXWorkspaceAudioEngine *e, uint64_t now) {
  e->sync([=] {
    if (!e->hardware)
      e->tick(now);
  });
}
}
