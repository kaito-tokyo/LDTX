<!-- SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo> -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Workspace audio engine

`LDTXAudioEngine` owns capture, monitoring, timed mixing and PCM output for one
Workspace. Its C interface is declared in `WorkspaceAudioEngine.h`.
`WorkspaceAudioEngine` in ProgramRuntime supplies settings and subscriptions;
recording, streaming and spectrogram clients receive independently owned
`CMSampleBuffer` memory. Video capture and Player playback are separate.

```text
Physical input UID → input-only AUHAL → planar Float32 + AudioTimeStamp
  → shared PCM slots
    ├─ Monitor descriptors → AUConverter → MultiChannelMixer Device Gain
    │                                    → Monitor Master Gain → output AUHAL
    ├─ mix descriptors → 48 kHz stereo timeline → Device Gain → Master Gain
    │                                            → peaks + CMSampleBuffer
    └─ raw descriptors → native-rate/channel ungained CMSampleBuffer
```

## Hardware and monitoring

Each physical UID has one input AUHAL per Workspace. Logical routes share that
input. Recording start/stop and Monitor selection never reopen it. Input loss or
format changes rebuild only that input and increment its generation. Missing
inputs yield silence in the mix, while raw output retains timestamp gaps.

The dropdown beneath Monitor Master Gain stores the selected output UID in
`tokyo.kaito.ldtx.monitor-output-device-uid`. An empty selection disables Monitor;
a missing selection reports an error without choosing a substitute. System
default-device changes are not followed. The output AUHAL requests 128 frames
and logs the value read back from that unit. Input buffer sizes are unchanged.
No system default, hardware format, hardware gain or hog mode is changed.

AUConverter feeds a MultiChannelMixer input bus for each physical input. Enabled
logical gains for a shared device are summed at that bus. The mixer's output gain
is the distinct Monitor Master stage. Route mute and gain changes update Audio
Unit parameters without rebuilding the graph. There is no EQ, AVAudioEngine,
PlayerNode, Varispeed, scheduled playback or recording worker in this path.

Monitor renders on the output Audio Unit callback. Capture synchronously copies
AudioUnitRender's buffer into preallocated slots. Both callbacks avoid heap
allocation, locks, logging and Swift calls. Monitor obtains a generation-checked
lease by CAS, reads partial blocks and releases the lease. On acquiring a new
block it discards backlog older than the newest two descriptors. Missing frames
are silence. This bounded backlog policy does not correct input clock skew and
must not be used for recording's timeline.

## Ownership and worker

Each input reserves five seconds of slots at its hardware quantum, rounded up to
whole slots. Each payload supports the negotiated maximum callback length.
Three bounded SPSC queues carry timestamped descriptors, not copied PCM.
Mix and raw each hold a strong bit. Monitor holds no slot until a matching
generation and its read-protection bit can be acquired atomically. The writer
reuses only unheld slots. Capacity exhaustion drops new data, preserving the next
block's actual acquisition timestamp. No NaN markers or ARC weak pointers are used.

A dedicated worker handles normalization, timelines, mix gain interpolation,
CMSampleBuffer allocation, subscription delivery and hardware control. Published
samples copy their PCM out of the input ring; a slow external owner cannot retain
capture slots. Unsubscribe fences notifications, including queued notifications.
Stop disables delivery, stops the Monitor and input units, waits for active
render callbacks, then releases queues, subscriptions and buffers.

## Time and output

Valid host timestamps map to the same host clock used by video. Sample-only time
requires a host/sample anchor in the same input generation. Unmappable timestamps
are discarded and counted; callback arrival time is never substituted.
Normalization uses stereo Float32 at 48 kHz. Mono is duplicated; stereo is retained;
additional channels are omitted from the mix but remain in raw output. Conversion
resets at timestamp discontinuities. One-frame rounding differences are joined
only when acquisition times are contiguous.

Mix buses share a 48 kHz clock and render 1024-frame blocks after a 200 ms delay,
with at most eight catch-up blocks per worker tick. A missing input range silences
that input for the entire block. Device and Master gains remain separate stages.
The actual mix supplies Master peaks. Identical preview/output configurations
share a bus; a replacement bus joins the existing clock instead of adding a new
200 ms startup wait. PTS uses a 48 kHz timescale to avoid nanosecond-rounding gaps.

Recording subscriptions wait for the first video boundary, then deliver whole
shared-mix blocks at or after it. The initial audio boundary can therefore follow
video by less than one 1024-frame block. Source changes preserve the subscription's
last-delivered time fence. Container-specific timestamp mapping stays in the
existing output services. Raw output has no gain, Monitor backlog trimming or
mix deadline applied to it.

## Validation

The native test executable covers ring wrap, stale generations, concurrent raw,
mix and Monitor consumers, overflow, timestamp mapping, 44.1/48 kHz conversion,
mono duplication, cancellation, two gain stages, deadline silence, catch-up limits,
reconnection and subscription time fences. Run it outside the sandbox with:

```sh
Tests/LDTXAudioEngineNativeTests/run-tests.sh
```

The script enables Thread Sanitizer and uses a temporary build directory.
`LDTXAudioRuntimeTests` and `LDTXAppLifecycleTests` cover Swift integration.
Physical unplug/replug, long-duration A/V synchronization and acoustic latency
remain hardware measurements; queue depth and peak display are not latency measurements.

### Local validation on 2026-09-07

- Debug builds: LDTX, LDTXTiny, their bundled CLI helpers, and LDTX Player succeeded.
- Native tests: Thread Sanitizer passed, including retained raw buffers and
  concurrent unsubscribe fencing, bounded backlog fairness, input fault
  isolation, and idempotent stop completion.
- App lifecycle: 10 XCTest and 112 Swift Testing cases passed.
- Runtime/capture excluding the remux suite: 145 XCTest and 74 Swift Testing cases passed,
  including concurrent cancellation waiting for an active notification.
- The remux suite's 17 cases passed in isolation. Combined runs intermittently
  crashed in MediaToolbox / CFArrayGetCount during
  `syntheticRecordingFinalizesAndRemuxesToOneMultitrackMP4`; this remains unresolved.
- Elgato Game Capture Neo and HyperX inputs ran together. Unit readback logged
  512 input frames and 128 output frames. Removing/restoring Monitor selection
  and starting/stopping recording produced no additional input-start events.
- The final Debug build produced a finalized approximately 25-second recording
  with Landscape, Portrait and two raw tracks. All four AAC tracks were 48 kHz
  stereo with strictly increasing packet PTS and no packet interval exceeding
  one AAC frame (1024 samples, allowing timestamp display rounding).
- Acoustic monitoring confirmation for this rewrite, latency comparison,
  physical hotplug, actual Program-switch A/V alignment and long-duration drift
  were not completed. No claim of zero latency is made.

## Handoff: agreed lifecycle changes still to implement

Input Devices configuration is immutable while output is active. Explicit
configuration edits may therefore stop, dispose and rebuild the entire Workspace
audio pipeline; continuity across that rebuild is not required. Physical hotplug
is different: retain the configured logical input, substitute silence while it is
unavailable, and reacquire its format when the same UID returns. Other inputs and
the output timeline remain active. Monitor output loss stops Monitor only.

Treat successful AudioOutputUnitStop on the control thread as a synchronous I/O
callback stop boundary. This is an agreed engineering assumption supported by the
historical Apple engineer explanation reproduced at
https://developer.apple.com/forums/thread/117962; the current API reference does
not explicitly document the full synchronization contract. Do not replace that
boundary with a fixed timeout, or treat a stop error as successful quiescence.

Use ResourceTaskQueue's lifecycle as the model for downstream delivery: serialize
submission closure with acceptance, discard pending work for reconstruction, wait
for running work, and complete all stop waiters at the terminal state. Normal
recording finalization instead drains required deliveries. Keep this coordination
outside real-time callbacks and implement the native path in C++.

WorkspaceCaptureSessionCoordinator currently conflates rejected stale callbacks
with accepted dispatches having no subscribers. The rejection does not increment
inFlightSampleDispatchCount, but the empty-handler path decrements it. Resolve
this mismatch during lifecycle cleanup and add regression coverage.

The full Debug app builds and lifecycle tests above predate the final backlog and
cancellation hardening. Native TSAN and runtime tests passed after their respective
changes, but the final full app rebuild/relaunch was blocked by execution approval
review's usage limit. Repeat that build on the destination machine. Physical
hotplug, long-duration synchronization and acoustic measurements are deferred.
The intermittent remux crash is tracked separately at
https://github.com/kaito-tokyo/LDTX/issues/246. The initial whole-block audio boundary
and slight Program gain-update lag on a continuous PTS timeline are accepted
design behavior, not pending defects.
