<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Testing Policy

## Presentation timestamp testing

Presentation timestamps (PTS) determine audio continuity, audio/video
synchronization, capture ordering, frame pacing, and the validity of recorded
and streamed media. PTS regressions may only appear after a long-running
session or in a generated media file, so PTS tests are intentionally more
thorough than tests for ordinary value transformations.

Do not remove or combine a PTS test solely to reduce the number of test cases.
A PTS test may be removed only when another test exercises the same production
path, timing condition, and observable output at an equal or higher level.
Keep the reason for equivalence clear in the change description.

PTS behavior should be covered at three levels:

1. **Timing primitives:** Verify exact `CMTime` values for clocks and timelines,
   including anchors, frame-count advancement, gaps, overlaps, partial ranges,
   buffer overflow, invalid timestamps, and differing timescales or sample
   rates.
2. **Runtime integration:** Verify that capture, mixing, monitoring, and frame
   pacing preserve the selected source PTS. Cover delayed, missing, duplicated,
   and out-of-order input without relying on wall-clock sleeps.
3. **Media output:** Read generated MP4 or DASH output and verify that audio and
   video sample timestamps are valid and strictly increasing, tracks begin at
   the expected normalized time, and track durations remain synchronized.

At minimum, changes to timing or media pipelines must retain coverage for:

- audio-first and video-first startup;
- discontinuous or late audio relative to the video anchor;
- repeated or non-increasing video PTS;
- source sample-rate conversion and normalized audio continuity;
- missing input and output underflow;
- large nonzero PTS representative of a long-running session;
- frame-rate changes and missed rendering deadlines; and
- persisted selection of the program's audio and video PTS sources.

### Required PTS scenarios

Use the following scenarios when selecting or reviewing PTS tests. A single
parameterized test may cover multiple rows, but its assertions must identify
which scenario failed.

| Scenario | Input and operation | Required observations |
| --- | --- | --- |
| Initial anchor | Start a timeline with a valid, nonzero PTS. | The first output PTS equals the selected anchor exactly; it is not replaced by zero or the host clock. |
| Continuous audio | Submit consecutive audio buffers with different frame counts. | Each output PTS equals the preceding PTS plus the preceding frame count at the output sample rate. There are no gaps caused by buffer boundaries. |
| Sample-rate conversion | Normalize 44.1 kHz input onto the 48 kHz program timeline. | Source time is mapped without drift, output format is correct, and consecutive normalized buffers remain contiguous. |
| Discontinuous audio anchor | After the timeline starts, submit a buffer whose source PTS jumps forward or backward. | The established output clock remains monotonic and advances by rendered frame count; the later source anchor does not reset it. |
| Invalid PTS | Start with an invalid PTS, and separately submit an invalid PTS after a valid start. | Invalid initial state is rejected. An invalid later anchor does not corrupt an established timeline. |
| Audio before video | Deliver audio at the first video PTS before delivering that video frame. | The writer starts once both tracks are usable and emits valid initialization and media segments without shifting either track incorrectly. |
| Video before audio | Queue video before the first usable audio buffer, including audio that begins later than the first video PTS. | Pending video is retained as required, the writer starts, and output track start times and durations remain synchronized. |
| Missing or late audio source | Render a program audio interval when one or all expected sources have no complete range. | Complete sources are preserved, missing sources are reported or replaced with silence, and output PTS remains continuous. |
| Overlap and partial range | Insert overlapping buffers and request a range that crosses present and missing samples. | The documented later-sample precedence is applied, completeness is reported correctly, and samples stay aligned to the requested PTS. |
| Timeline capacity overflow | Advance a bounded timeline beyond capacity, including incremental and partially overlapping inserts. | Expired frames are dropped, every frame still inside the window is retained, and retained samples keep their original PTS alignment. |
| Repeated video PTS | Submit two or more video frames with the same PTS while audio continues. | Non-increasing video samples are rejected or dropped according to the writer contract; emitted video PTS values are strictly increasing and audio continues. |
| Out-of-order delivery | Deliver scheduled capture frames later or in a different cadence from their source timestamps. | Capture and runtime components preserve source PTS rather than deriving it from delivery time. |
| Large PTS | Start audio and video at the same large nonzero time representative of a long-running session. | Output is normalized to the intended start, audio and video remain aligned, and no overflow or precision loss shortens either track. |
| Output underflow | Advance the output driver while source audio is absent. | Silent buffers continue at exactly one buffer-duration interval and PTS never stalls, repeats, or follows wall-clock jitter. |
| Missed render deadline | Advance the deterministic render clock past one or more frame deadlines. | The pacer skips missed deadlines without a catch-up burst and schedules the next frame on the correct cadence. |
| Frame-rate change | Change the configured frame rate while a pacing schedule exists. | The old schedule is discarded and the next frame establishes a new cadence without inheriting an invalid fractional interval. |
| Persisted PTS source | Round-trip a program with explicit audio and video PTS source keys, and load legacy ordinal keys. | Explicit selections survive persistence and legacy selections migrate to stable mapping keys. |
| Encoded media inspection | Encode short MP4 or DASH output, then read audio and video samples back. | Every PTS is valid and strictly increasing per track; start times, sample counts, and durations agree with the synthetic input within an explicit tolerance. |

For synchronization scenarios, assert track start times and durations rather
than only checking that a file or segment exists. For long sequences, compare
timestamps as rational `CMTime` values where possible; use a documented
tolerance only at codec or container boundaries where exact equality is not a
stable contract.

### Multi-source synchronization contract

LDTX combines independently clocked camera, microphone, generated-audio, and
silent-audio sources into one program. Arrival time is not presentation time:
a delayed sample keeps its source PTS, and a sample that arrives quickly is not
necessarily the next sample to present.

The program video PTS source is the master timeline for an output session. The
audio mixer places every normalized audio source on that timeline and emits
fixed-size output buffers. Other video sources contribute their latest
available image to the composition but do not advance the program clock.

The target behavior is:

- choose the configured video PTS source before output starts;
- establish the session epoch from the first valid frame of that source;
- do not change the master source or epoch implicitly during the session;
- preserve each secondary video's latest usable image until a newer usable
  frame arrives;
- align audio by PTS ranges, never by callback arrival order;
- wait only for the configured bounded audio latency;
- after that deadline, mix every complete source and substitute silence for
  each missing or incomplete source;
- never revise audio or video that has already been emitted when a late sample
  arrives; and
- keep output PTS continuous during source starvation once the output timeline
  has started.

A fallback master, host-clock master, or session restart is a policy decision,
not an automatic consequence of whichever callback arrives next. If the
configured master never produces a valid frame, output must remain in an
explicit `waitingForMasterPTS` state until the caller selects one of those
policies. The implementation must not silently alternate between camera clocks.

The output-start policy is intentionally video-led:

- before any video PTS anchor exists, normalized and generated audio is not
  inserted into the program timeline and the audio output driver emits
  nothing.

When inspecting encoded samples with `AVAssetReader`, ignore buffers whose
sample count is zero. The reader may emit a leading format-only video buffer
with a placeholder timestamp; it is not a media sample and does not indicate a
duplicate encoded PTS.

#### Multi-source and starvation scenarios

| Scenario | Required setup | Required behavior |
| --- | --- | --- |
| Two synchronized cameras | Two cameras produce equal PTS values at different callback times. | The selected master advances output. Callback order does not affect output PTS, and the secondary image selected for composition is the newest image whose policy permits use. |
| Secondary camera ahead | The secondary camera's latest PTS is ahead of the master. | It does not advance the program clock. The frame is held or rejected according to the composition policy and must not be presented as though it belonged to the master's current PTS. |
| Secondary camera behind | The secondary camera is several frames behind the master. | The last usable secondary image is frozen while master output continues. Audio and master video are not stalled. |
| Secondary camera stops | One non-master camera produces no further samples. | Its last usable image remains visible, or the configured missing-source placeholder is used. Program PTS remains continuous. |
| Master camera delayed at startup | Secondary video and audio arrive, but the selected master has not produced a valid frame. | Output stays in `waitingForMasterPTS`; no secondary clock silently becomes the session epoch. |
| Master camera stalls after startup | The master stops while secondary cameras and audio continue. | Already emitted PTS is never repeated. The runtime follows an explicit freeze, host-clock continuation, fallback, or restart policy and reports that transition. |
| Master camera resumes | The master resumes after a stall with a PTS that is continuous, ahead, or behind. | Continuous input resumes normally. A forward discontinuity follows the gap policy. A repeated or backward PTS is rejected and cannot move output time backward. |
| Master source is switched | The user explicitly changes the PTS source during output. | The runtime either rejects the change until restart or starts a new synchronization epoch. It never splices unrelated clocks without an explicit mapping. |
| Two aligned microphones | Both sources contain the entire requested PTS range but arrive in different callback order. | Both are mixed at the requested positions; callback order has no effect. |
| One microphone late within budget | One source arrives after the other but before the audio deadline. | The mixer waits within the bounded latency and includes both sources without changing output PTS. |
| One microphone misses deadline | One source has no complete requested range at the deadline. | Complete sources are mixed, the missing source contributes silence, underflow is reported, and output PTS advances exactly one buffer. |
| Late audio after deadline | A missing range arrives after silence for that range was emitted. | The late range is discarded for output already emitted. It must not overwrite, duplicate, or shift future audio. |
| Partial audio range | A source covers only the beginning or end of the requested output interval. | The source is treated according to one explicit policy: reject the incomplete source for that block, or mix covered frames and silence only the gap. The selected policy must be tested at both boundaries. |
| All microphones absent at startup | Video establishes the master PTS but no audio samples ever arrive. | After the latency budget, silent audio starts at the video-aligned PTS and continues without gaps. |
| All microphones stop | Audio was present and then every source stops. | Output changes to silence at the next missing range without resetting the audio clock. |
| Microphone resumes | A source resumes after several silent output blocks. | Only samples covering future, not-yet-emitted ranges may be mixed. Past samples are discarded. |
| Different source sample rates | Sources at 44.1 kHz, 48 kHz, or another supported rate run together. | Each is normalized independently; their frame ranges align to one 48 kHz program timeline without cumulative drift. |
| Independent source drift | One hardware clock slowly gains on another over a long simulation. | The documented drift policy bounds skew without discontinuous output PTS, uncontrolled buffer growth, or repeated sample ranges. |
| No video and no audio | No source ever produces a sample. | The runtime remains waiting and can stop or finish without hanging, leaking tasks, or producing an invalid media file. |
| Source disappears during finish | A source stops or sends a delayed callback while the writer is finishing. | Finish completes once, late callbacks are ignored safely, and the final per-track PTS remains monotonic. |

The partial-range, master-stall, and clock-drift rows deliberately require a
named policy. A test is not complete if it merely records the implementation's
accidental behavior; the chosen policy must be documented alongside the test.

For every multi-source scenario, record at least these observations:

- master input PTS and emitted program video PTS;
- requested audio range and each source's available range;
- missing-source set at the audio deadline;
- emitted audio PTS and frame count;
- source-to-master skew; and
- whether a frame was used, frozen, replaced with silence, dropped, or caused
  a synchronization epoch change.

Prefer deterministic clocks, manually delivered frames, and short synthetic
media over sleeps and real capture devices. Parameterize equivalent format or
offset combinations within one test when they share a behavior contract, but
do not collapse distinct timing boundaries into a single happy-path case.

Fast timing tests belong in the default `swift test` run. Tests that encode or
inspect substantial media may use the heavy-media gate, but they remain part of
the required PTS regression suite and must be run when changing timing,
capture, audio, MP4, DASH, or runtime scheduling code:

```sh
LDTX_RUN_HEAVY_MEDIA_TESTS=1 swift test --filter LDTXMP4Tests
```

To inspect the main stream from an actual LDTX recording with the same
`AVAssetReader` monotonicity checks, provide its path explicitly:

```sh
LDTX_EXTERNAL_RECORDING_PATH=/path/to/recording.ldtxrecord/main-stream.mp4 \
  swift test --filter FileMP4WriterTests.testExternalRecordingPTSIsMonotonic
```

A skipped heavy-media test is not evidence that its PTS behavior passed. Code
review and continuous integration should distinguish the default test result
from a completed heavy PTS regression run.
