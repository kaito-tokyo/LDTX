<!-- SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo> -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Workspace audio monitoring

`LDTXAudioMonitor` uses standard Audio Units for hardware input, conversion,
mixing and output. `AudioHardwareSystem` resolves device UIDs and HAL property
listeners detect availability and format changes. There is no AVAudioEngine,
SourceNode, PlayerNode, EQ or Varispeed in the monitor graph.

```text
Physical input (one input-only AUHAL per UID)
  → Float32 at the device's sample rate
  → preallocated SPSC PCM ring
  → AUConverter (output sample rate and channel layout)
  → MultiChannelMixer input bus (Device Gain and route mute)
  → MultiChannelMixer output gain (Monitor Master Gain)
  → output-only AUHAL (explicitly selected output device)
```

The dropdown beneath Audio Mix’s Monitor Master Gain stores the selected output UID under
`tokyo.kaito.ldtx.monitor-output-device-uid`. Unselected output means monitoring
is disabled. A missing selected device produces a visible error beneath the dropdown; it never
falls back to another device. OS default-device changes are not observed. Device
reconnection can restore the same selected UID. Selection changes rebuild only
the monitor, leaving the separate recording/streaming input pipeline running.

The monitor never changes the system default devices, hardware formats, hardware
volume or hog mode. The output AUHAL requests a 128-frame device I/O buffer for
the latency comparison; input buffer sizes are left unchanged. The requested
size is read back through each AUHAL and logged. A separate HAL client may report
a different size, so an external device query is not used to validate this setting.
AUHAL's CurrentDevice selects that unit's device;
it does not change the system default. Client PCM is planar Float32. AUConverter
handles sample-rate and channel conversion for each physical source.

Identical physical samples are consumed only once. If several logical routes
reference a physical input, their enabled linear gains are summed on its mixer
input bus. This is equivalent to summing their separately gained samples. Master
gain remains a distinct output stage. Mixer Audio Unit volume accepts finite
gains above unity, unlike the documented AVAudioMixerNode outputVolume range.
Mute/gain changes do not reopen input devices or rebuild the graph.

The ring target is one input hardware quantum. Rendering reads immediately;
there is no wait for a target to fill. Missing frames become silence. Backlog
above two targets is trimmed to the current request plus one target. Overflow
drops new input blocks without overwriting unread storage. There is no continuous
rate skew: independent clock drift can cause occasional frame drops or silence.
This is intentionally a monitoring-only discontinuity policy, not recording sync.

Both Audio Unit callbacks execute in C with preallocated buffers. Capture calls
AudioUnitRender and synchronously copies its result into the ring. Output pulls
through converter and mixer callbacks. All requested sizes and plane layouts are
checked before copying; oversized callbacks return an error instead of allocating.
Statistics include accepted, buffered, dropped, missing frames and render errors;
they do not measure acoustic latency. The output starts before inputs, so initial
missing-frame counts include startup silence.

Shutdown stops output and input units before disposing consumers and freeing
callback contexts. Hardware notifications carry a generation to reject obsolete
queued work. Monitoring errors are reported independently and do not prevent
recording or metering from starting. Recording/streaming still use the existing
AVCapture/composition pipeline and receive no monitor gain or backlog correction.

Validation includes offline Audio Unit tests at 44.1 and 48 kHz, amplification at
two stages, mute, ring wrapping, underflow and backlog removal. Live validation
with four inputs and five logical routes confirmed Elgato audio at the selected
HyperX output, stable identities across mute changes, reconstruction and shutdown.
End-to-end acoustic latency and physical unplug/replug remain separate hardware
checks; queue occupancy is not an acoustic latency measurement.
