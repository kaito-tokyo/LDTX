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

## Lifecycle contract and follow-up validation

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
If `AudioOutputUnitStop` fails, the control thread retries at most three times
after the initial attempt, waiting 10 ms before each retry. If all four attempts
fail, it logs the final status and calls `abort()` without disposing callback
resources. The delay is a retry interval, not evidence of callback quiescence.

The native C++ delivery queue serializes acceptance and closure on the control
worker. It yields between notifications to pending control commands, preserving
pending deliveries for ordinary commands and discarding them for reconstruction
or shutdown. Reentrant input reconstruction waits until the active notification
returns before replacing its input generation. Stop completions run after
shutdown reaches its terminal state. This follows ResourceTaskQueue's lifecycle
model, outside real-time callbacks. Normal recording finalization instead drains
its accepted media before finishing the package.

WorkspaceCaptureSessionCoordinator distinguishes rejected stale callbacks from
accepted dispatches having no subscribers. Rejected callbacks neither increment
nor decrement the in-flight dispatch count. Regression coverage keeps a retired
capture alive while an accepted callback is blocked and verifies that a stale
callback cannot prematurely complete the unsubscribe fence.

Follow-up validation on 2026-09-07 passed the native Thread Sanitizer suite,
`LDTXAudioRuntimeTests`, and `LDTXAppLifecycleTests`. The native stop test includes
multiple pending catch-up notifications behind a blocked callback and two stop
waiters. Failed-stop injection covers zero through four failures and checks the
attempt count and final status; it does not reproduce a physical AUHAL failure.
Physical hotplug was not yet validated at that stage; subsequent results appear
below. A still-missing input retries without tearing down healthy Monitor
readers; its graph changes only on successful reconnection.
The final full LDTX Debug build and deep signature verification also passed.
The old app process was normally terminated, and the rebuilt app was launched
and verified at its launcher window. This launch check is not an acoustic or
physical-device validation.
The intermittent remux crash is tracked separately at
https://github.com/kaito-tokyo/LDTX/issues/246. The initial whole-block audio boundary
and slight Program gain-update lag on a continuous PTS timeline are accepted
design behavior, not pending defects.

### Individual recording gap experiment

The physical Elgato unplug/replug recording on 2026-09-07 retained continuous
Main Mix and HyperX audio, but its individual Elgato file collapsed approximately
69 seconds of missing input. The recording lasted approximately 163 seconds;
the Elgato file contained approximately 94 seconds. A synthetic PCM writer test
reproduced this: one second of PCM, a two-second PTS gap, and another second of
PCM produced a file lasting approximately 2.004 seconds without compensation.

The experimental recording writer fills positive PCM gaps before AAC encoding,
in chunks of at most 1024 frames when the writer is ready. Capture and raw
subscription timestamps are unchanged. Recording finalization supplies the
latest normalized media end across tracks to fill a disconnected track's tail;
it does not derive that boundary from wall-clock time. Existing nonzero initial
presentation offsets remain preserved. If a track never receives any sample,
finalization creates a recording-only 48 kHz stereo silent track from zero to
the shared media end. This fallback is not a claim about the missing physical
device's format. It is deferred until finalization so that a late first sample
can still determine the actual recording format. A track that received a sample
but subsequently failed is not replaced by this fallback. Without a positive
shared media end, no silent recording is fabricated.

Decoded-file tests verify sound before and after the gap at its original time,
silence inside the gap and at the padded tail, and preservation of the existing
initial-offset behavior. Standalone package finalization and remux tests passed
with and without input gaps. A combined test run crashed on CoreMedia's
assetwriter queue in CFDictionaryGetCount; its relationship to issue #246 is
unconfirmed; an isolated successful run does not resolve that failure.

Physical validation with the compensated Debug app passed both cases:

- `LDTX20260907T224926.698.ldtxrecord`: Elgato and HyperX individual audio
  ended at 154.645333 seconds. Elgato decoded silence from 46.584562 to
  128.660646 seconds, including the disconnected interval and source recovery.
  Sound resumed afterward without collapsing the missing interval.
- `LDTX20260907T225423.986.ldtxrecord`: Elgato remained disconnected through
  normal recording stop. Its audio ended at 51.690666 seconds, with decoded
  silence from 21.763833 seconds through the end. HyperX ended at 51.712 seconds;
  the difference is one AAC frame.

Both packages finalized normally. Main Mix and both individual audio tracks
had strictly increasing packet PTS with a maximum step of approximately
21.334 ms. These checks validate gap and tail compensation, not acoustic A/V
alignment or behavior after a sample-rate/channel-count change.

Start-without-input validation on 2026-09-08 also passed. Elgato was unplugged
before launching the rebuilt Debug app and stayed absent through recording stop.
`LDTX20260908T003334.375.ldtxrecord` finalized normally; its Elgato track was
48 kHz stereo with decoded zero amplitude throughout 0–15.701333 seconds.
HyperX ended at the same timestamp, while video ended at 15.671667 seconds.
All audio packet PTS increased strictly with a maximum step of approximately
21.334 ms. The finalization log confirmed the no-input fallback was used.
Synthetic package finalization/remux coverage also checks the entirely silent
track after decoding. PCM writer tests cover absent, zero and negative end
times without fabricating segments, and preserve an injected writer failure.

### Timing responsibility and acceptance criteria

LDTX's timing responsibility is continuity on the media timeline, not content
synchronization between independent inputs. Users supply any synchronization
signals, reference events and source-device configuration needed for their
production. Input-to-input acoustic alignment and identical track endpoints
are not acceptance criteria for these recording tests.

Recording, playback and remux must preserve the represented timeline: missing
input must not collapse elapsed media time, and reconnection must not rewind
the timeline. A leading empty interval may be represented by the manifest's
presentation position rather than encoded silence. An individual media file
alone does not necessarily carry that package-level position. Silence used to
represent missing input does not claim that the physical source supplied it.
Timestamp errors introduced by LDTX remain in scope; endpoint differences alone
neither establish such an error nor establish its cause.

### Further physical validation on 2026-09-08

All recording packages named below are retained in the local Movies directory.

- Late first input, `LDTX20260908T011007.621.ldtxrecord`: playback composition
  contained an empty leading interval of 79.405428 seconds for Elgato. LDTX
  remux produced an MP4 with Elgato starting at 79.406667 seconds and ending
  at approximately 114.244 seconds. This validates placement, not acoustic sync.
- Repeated disconnect/reconnect, `LDTX20260908T013424.609.ldtxrecord`: the user
  confirmed sound returned after all three requested cycles. The package
  finalized normally. All audio packet PTS increased strictly, with maximum
  steps of approximately 21.334 ms. LDTX playback composition and remux completed;
  decoded silence durations were unchanged after remux, including the three
  later intervals of 46.833437, 29.108854 and 35.831979 seconds. This was an
  operator-paced test, not a rapid hardware stress test. Elgato's endpoint was
  approximately 1.60 seconds later than HyperX's; this is an observation, not
  a failed endpoint-equality requirement or a determined cause.
- Monitor/input disconnect, `LDTX20260908T020537.966.ldtxrecord`: HyperX USB
  removal disconnected both its input and the selected Monitor output. Elgato
  remained connected during that portion of the test. Recording continued,
  the user confirmed Monitor sound returned after reconnection, and the package
  finalized normally. HyperX silence spanned 208.279271–316.672500 seconds.
  Elgato had no silence of at least three seconds during that interval at the
  -70 dB detection threshold; Main Mix had none throughout the recording.
  All audio packet PTS increased strictly with maximum steps of approximately
  21.334 ms. An earlier accidental Elgato removal is separately represented by
  silence at 80.398417–168.769667 seconds; it is not the Monitor test interval.

Channel-count changes remain unverified on physical hardware.
The combined-test CoreMedia crash noted above remains unresolved; successful
isolated physical-package remux runs do not close that issue. These results do
not establish content synchronization precision between independent devices.

### Sample-rate change regression

HyperX input was changed from 48 kHz to 44.1 kHz and back during
`LDTX20260908T021649.056.ldtxrecord`, then restored to 48 kHz. The package
finalized and decoded, but these checks alone did not prove elapsed-time
preservation. A synthetic contiguous 22-second input reproduced compression to
20.393333 seconds when its middle 20 seconds used 44.1 kHz. Using 96 kHz for
that interval instead produced 42.004 seconds.

The PCM writer now explicitly normalizes incoming PCM to its initial recording
sample rate and channel count before passing it to AVAssetWriter, retaining
source presentation timestamps. The normalizer's existing default remains
48 kHz stereo for other callers. Capture data is not changed by this
recording-only conversion.

All three synthetic cases now produce approximately 22.015 seconds. Decoded
windows before, during and after the change retain a 440 Hz test tone. Existing
PCM gap, initial-offset, empty-input and failure tests also pass, as do the
three synthetic package finalization/remux cases. The Debug app builds;
physical revalidation with this fix is still pending.
