<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Intermittent recording writer crash investigation

Status: reproduced independently; an AAC passthrough workaround is implemented
and locally validated. Issue #246 has not been closed. These experiments do not
establish Apple's internal root cause or prove that every historical crash has
the same cause.

## Issue context

- [Issue #246](https://github.com/kaito-tokyo/LDTX/issues/246) describes an
  intermittent MediaToolbox crash in the combined `LDTXAudioRuntimeTests` suite.
  Its isolated recording/remux suite passed. The reported stack includes
  `__CF_IS_OBJC`, `CFArrayGetCount`, and CoreMedia deferred notifications.
- [Issue #176](https://github.com/kaito-tokyo/LDTX/issues/176) describes an earlier
  recording-cut crash involving `CFDictionaryGetCount`. Its resolution added
  a process-wide writer lifecycle gate. Similar frames alone do not establish
  that the present failure has the same cause.

## Local observations on 2026-09-08

Tests ran on macOS 26.6.2, arm64, in the primary checkout, based on commit
`2bf9bcb`. The reproduction and isolation observations below precede the AAC
passthrough candidate described separately. Gate and report-handling experiment
changes were reverted.

The original-style Xcode combined suite passed once, followed by three successful
`test-without-building` runs. Results are under
`/private/tmp/LDTX-issue246-xcode.3krANY` on the investigation machine.

Additional synthetic recordings use three seconds of H.264 video and PCM input,
with a 0.2-second side-track offset. A recording contains the main muxed writer
and a PCM side writer unless noted otherwise.

| Control | Observation |
| --- | --- |
| Six concurrent recordings, mixed input-loss cases, with inspection/remux | SIGTRAP after the first group of six. |
| Same workload without remux, but with inspection/verification | SIGTRAP after the first group. |
| Without inspection, verification, or remux | SIGTRAP after two groups. |
| Continuous input only, six concurrent recordings | SIGSEGV reproduced. |
| Continuous input, recording-only, 30 sequential recordings | SIGSEGV after 18 completed recordings. |
| Include `startSession` and `markAsFinished` inside the lifecycle gate | SIGSEGV still reproduced; experimental change reverted. |
| PCM writer alone, 30 sequential lifecycles | Passed; also passed with the side-track offset and explicit end time. |
| Main recording alone, 30 sequential lifecycles | Passed. |
| Both writers, Zombie diagnostics enabled | 30 recordings passed; no deallocated-instance diagnostic established the cause. |
| Retain both recorders until the test ends | 30 recordings passed once. |
| Retain only the main recorder | Crash after 26 completed recordings. |
| Retain only the side recorder | Passed once, then SIGTRAP after 25 completed recordings on repetition. |
| Extract PCM segment-report timing inside the delegate callback | Two 30-recording runs passed, then a repeat crashed after two completed recordings. |
| Extract report timing inside all three writer delegate callbacks | Crash after 25 completed recordings; experimental changes reverted. |
| PCM writer alone, increased iteration budget | Crash after 25 completed lifecycles; the earlier passes did not exclude this writer. |
| Direct AVAssetWriter PCM encoding, without LDTX wrappers | Crash after 181 completed lifecycles. |
| Standalone AVFoundation-only executable, alternate PCM buffer construction | SIGSEGV; same `CFDictionaryGetCount`/qtmovie frame family. |
| Standalone executable, first PCM PTS set to zero | 300 lifecycles passed, but a subsequent 1000-lifecycle attempt crashed. |
| Standalone executable, segment interval longer than the recording | SIGSEGV after 155 completed lifecycles. |

Thus remux, asset inspection, input loss, and multiple concurrent recordings are
not necessary for the observed stress-test crashes. Recorder retention has not
proved sufficient to prevent them. Passing isolated controls is not proof of
absence of a fault in either writer.

Further iteration reproduced the crash in the PCM writer alone and then in a
standalone executable that does not link LDTX or Swift Testing. The standalone
sample generator uses `AVAudioPCMBuffer` and
`CMSampleBufferSetDataBufferFromAudioBufferList`, unlike the test's direct
CMBlockBuffer construction. A nonzero first PTS and intermediate segment
boundaries are not necessary. This establishes an LDTX-independent reproducer,
not a final diagnosis of an Apple defect or proof of API correctness.

The attempted `.indefinite` segment interval is not a valid control for a writer
performing AAC conversion: AVFoundation rejects that configuration with
`-11875`, requiring passthrough. That failure is not the intermittent crash.
The valid no-intermediate-boundary control instead uses a 10-second interval
for a 3-second recording.

Observed reports include both `CFDictionaryGetCount`/SIGSEGV and
`CFArrayGetCount`/SIGTRAP, on `com.apple.coremedia.formatwriter.qtmovie` or a
CoreMedia shared-root queue. Some use deferred notifications; others end in
`figThreadMain`. This resembles the reported failure family, but the original
Issue #246 crash report was not available locally for full comparison.

Representative local evidence:

- `/private/tmp/ldtx-246-serial-baseline.log`
- `/private/tmp/ldtx-246-expanded-gate.log`
- `/private/tmp/ldtx-246-main-only.log`
- `/private/tmp/ldtx-246-pcm-offset.log`
- `/private/tmp/ldtx-246-retained-side-repeat1.log`
- `~/Library/Logs/DiagnosticReports/swiftpm-testing-helper-2026-09-08-025338.ips`
- `~/Library/Logs/DiagnosticReports/swiftpm-testing-helper-2026-09-08-025926.ips`
- `/private/tmp/ldtx-246-pcm-300.log`
- `/private/tmp/ldtx-246-direct-pcm-300.log`
- `/private/tmp/ldtx-246-standalone-pcm-300.log`
- `/private/tmp/ldtx-246-standalone-zero-1000.log`
- `/private/tmp/ldtx-246-standalone-long-interval.log`
- `~/Library/Logs/DiagnosticReports/ldtx-pcm-writer-reproducer-2026-09-08-031144.ips`
- `~/Library/Logs/DiagnosticReports/ldtx-pcm-writer-reproducer-2026-09-08-031304.ips`

These local artifacts are temporary investigation evidence, not repository
fixtures or a guarantee of continued availability.

A debugger run captured SIGTRAP during the second recording, with one worker
and no retention. Another thread was executing the PCM segment delegate's
queued report-processing closure. This is a simultaneous observation, not proof
that the report processing caused the fault. Moving report extraction into the
delegate callbacks did not prevent subsequent crashes. The capture is in
`/private/tmp/ldtx-246-lldb-frameworks.log`.

The ordinary suite passed after the opt-in tests were added: 17 existing test
functions ran, and the four stress tests were skipped. This does not replace
stress validation or resolve the intermittent failure.

## Opt-in reproduction

Run outside the sandbox, with signing enabled as required by `AGENTS.md`:

```sh
LDTX_RECORDING_STRESS=1 swift test --filter \
  AudioSideStreamSegmentPipelineTests/concurrentRecordingWithoutRemuxLifecycleStress
```

This runs 30 groups, each containing one continuous-input recording by default.
It excludes asset inspection, verification, and remux. Set
`LDTX_STRESS_WORKERS=6` for six recordings per group. Worker counts are bounded
to 1–6. Set `LDTX_STRESS_RETENTION` to `main`, `side`, or `both` to keep those
recorders alive through the test; the default is `none`. Set
`LDTX_STRESS_ROUNDS` to change the number of groups/lifecycles (bounded to
1–300, default 30). `LDTX_STRESS_MIXED_INPUTS=1` cycles workers through continuous
input, intermediate/tail loss, and no input from startup; use six workers to
exercise all three modes together. Retention is strictly
a diagnostic control, not a production workaround.

Other opt-in filters in the same suite are:

- `concurrentRecordingRemuxLifecycleStress`
- `mainWriterOnlyLifecycleStress`
- `pcmWriterOnlyLifecycleStress`
- `directPCMAssetWriterLifecycleStress`
- `aacPassthroughAssetWriterLifecycleStress`

Run controls individually to avoid confounding them through Swift Testing's
parallel suite execution. The isolated controls run sequential lifecycles and
do not use the retention/worker options.

## Standalone reproducer

The script imports only Apple frameworks and does not create output files:
segment data is discarded by the delegate. Build and run outside the sandbox.

```sh
xcrun swiftc -parse-as-library scripts/reproduce-pcm-writer-crash.swift \
  -o /private/tmp/ldtx-pcm-writer-reproducer
/private/tmp/ldtx-pcm-writer-reproducer 300
```

The argument is the iteration count (1–1000). Optional controls are
`LDTX_REPRO_ZERO_OFFSET=1` (first PCM PTS zero instead of 0.2 seconds) and
`LDTX_REPRO_SINGLE_SEGMENT=1` (10-second instead of 2-second interval).
Normal Swift errors exit with status 1; distinguish them from a framework
signal and inspect the actual stack. The current version writes progress
without stdout buffering; earlier captures can end mid-line or contain no
progress lines, so they cannot establish an exact failure iteration.

## Remaining diagnostic limits

The live debugger capture, isolated controls, and standalone reproducer are
available. A pre-migration build comparison was not performed; independent
reproduction establishes that the new LDTX audio engine is not necessary for
this failure, but does not identify the root of every historical report. Apple's
internal fault and the exact equivalence to the original unavailable Issue #246
crash report remain unproven. The local workaround validation follows below.

## AAC passthrough candidate

The main recording pipeline passed 300 lifecycles. An audio-only control that
uses `AACAudioEncoder` followed by an AVAssetWriter input with nil output
settings also passed 300 lifecycles. These are empirical comparisons, not proof
that other writer configurations can never fail.

The candidate changes `PCMAudioSegmentedMP4Writer` to encode normalized PCM and
synthesized silence with the existing `AACAudioEncoder`. AVAssetWriter receives
AAC passthrough samples instead of performing PCM conversion itself. Encoded
samples have their own drain queue; finalization flushes the encoder and drains
all AAC before marking the writer input finished. PCM timing and silence
generation remain in the existing path.

Local workaround validation:

- The selected regression run passed: 28 XCTest cases with one heavy test
  skipped, plus 32 Swift Testing functions with six opt-in stress functions
  skipped. This includes rate/channel conversion, silence, and recording/remux
  checks.
- The PCM wrapper completed 300 lifecycles without a crash, versus a failure
  after 25 completed lifecycles in the earlier implementation.
- Six parallel recordings per group, 30 groups (180 recordings), including
  inspection, verification, and remux, passed with continuous input.
- The same 180-recording workload passed with continuous input, intermediate/
  tail loss, and no input from startup mixed across workers. The existing
  no-input case also decodes and checks the silent remux output.
- The original Xcode `LDTXAudioRuntimeTests` suite passed four times (one build
  and test, then three `test-without-building` runs). Every result bundle reports
  238 passed test functions, zero failures, and six skipped opt-in tests;
  parameter expansion yields 242 passing executions.

These observations support this workaround for the locally reproduced failure.
They do not prove that all possible framework crashes are eliminated. No new
physical-device recording session was performed with this workaround, and the
running GUI app was not replaced during the investigation.

Local candidate logs:

- `/private/tmp/ldtx-246-main-300.log`
- `/private/tmp/ldtx-246-aac-passthrough-300.log`
- `/private/tmp/ldtx-246-aac-candidate-regression.log`
- `/private/tmp/ldtx-246-aac-candidate-pcm-300.log`
- `/private/tmp/ldtx-246-aac-candidate-combined-180.log`
- `/private/tmp/ldtx-246-aac-candidate-mixed-180.log`
- `/private/tmp/LDTX-246-candidate.kPnuDH/combined.xcresult`
- `/private/tmp/LDTX-246-candidate.kPnuDH/repeat-1.xcresult`
- `/private/tmp/LDTX-246-candidate.kPnuDH/repeat-2.xcresult`
- `/private/tmp/LDTX-246-candidate.kPnuDH/repeat-3.xcresult`

## Follow-up: recording source-clock preservation

The physical recording `LDTX20260908T060342.546.ldtxrecord` exposed a separate
failure in the first AAC workaround. All three side tracks stopped accepting
audio about 15–18 seconds after startup, before the USB disconnect. AAC input
validation reported accumulated differences of 2.000640, 2.002608, and 2.058816
frames. Finalization subsequently failed. This recording is not a passing
hotplug result.

Recording timestamps preserve the input PCM clock, shifted by the recording
origin. The converter's cumulative sample-count clock is an internal encoding
detail, not the recording clock. Streaming remains on its existing output
clock; its AAC encoder continuity validation is unchanged.

The recording implementation keeps PCM frame-to-source-time anchors and uses
continuous timestamps only while encoding and muxing. Before persisting an
audio fragment, it rewrites the audio track timescale, decode base time, and
packet durations from that source mapping. AAC payloads and video timing are
unchanged; data offsets are adjusted when the fragment header grows. Output
timing has nanosecond resolution, rather than unlimited rational precision.
Anchors belonging to successfully emitted fragments are discarded while
retaining the final anchor for the following fragment.

AVAssetWriter did not preserve the supplied sub-sample AAC timing in local
tests. AVMutableMovie sample copying is therefore used for remuxing so that
the persisted media timing survives export. Regression tests compare packet
time differences before and after remux, independently of priming offsets.

Synthetic tests cover positive and negative source-clock drift, Main Mix and
individual inputs, missing input and silence, format conversion, and bounded
anchor retention.

The subsequent physical recording `LDTX20260908T070448.661.ldtxrecord` produced
about 66 seconds for Elgato and HyperX, but the mono Webcam file contained only
initialization data and package finalization failed. It is also not a passing
hardware result. A mono reproduction with a 20 microsecond input start exposed
an internal origin rounded upward, which mapped the muxer's zero-clipped AAC
priming boundary to a negative timestamp. The converter origin now rounds down;
the original source anchors retain the fractional start. Errors raised while
processing the final fragment are now returned by the finish completion too.

The stored fragment's first decode timestamp is 20 microseconds, independently
confirmed with ffprobe. AVAssetReader's compressed and decoded buffer starts
are not interchangeable with input PCM placement: priming, track edits, and
the decoder's sample-rate grid affect those buffers. Tests verify raw fragment
timing, successful PCM decoding, and the nonempty media segment's placement
after package remux separately. A track's overall time range can include an
initial empty edit and therefore is not the correct start-position assertion.

The package manifest previously used microsecond ticks, losing sub-microsecond
start offsets at remux. It now uses nanosecond ticks. Integration tests cover
starts of 1, 20,000, and 20,123 nanoseconds through package finalization,
verification, and remux, with less than half a nanosecond of allowed error.
All three cases pass.

The corrected signed build finalized the connected-device recording
`LDTX20260908T072934.802.ldtxrecord` (about 63 seconds) with all three inputs,
including mono Webcam, and the Main Mix. Strict package verification, CLI
remux, and full-track decoding succeeded. Comparing every AAC packet before
and after remux found identical payloads and constant per-track timestamp
shifts: zero variation across 2,968 Main Mix packets and 2,978 packets per
individual input. FFmpeg's null output required a fine video encoder time base
to avoid output-side timestamp rounding warnings.

Absolute Main Mix placement is not yet verified: remux shifted its packets by
-18.5 microseconds. Unlike individual inputs, the embedded Main Mix intentionally
does not use the video manifest start. New integration cases with Main Mix
starts of 1, 18,500, and 20,123 nanoseconds reproduce a zero output start instead
of the requested placement. Preserving the embedded audio's own start remains
an open implementation requirement. Hardware hotplug validation of the final
revision also remains pending.

The subsequent correction records the embedded Main Mix's first PCM PTS as an
optional manifest SupplementalProperty, independently of the video start.
All three Main Mix fractional-start integration cases now pass, as does the
legacy-package test that excludes the video manifest offset from Main Mix.
Parser coverage checks absent values, valid values, invalid integers, overflow,
and isolation between Representations. The corrected build also passed 30
groups of six concurrent recording/remux lifecycles with mixed continuous,
missing-tail/intermediate, and no-input cases (180 recordings). The log is
`/private/tmp/ldtx-source-clock-mixed-remux-stress.log`.

The final hotplug recording `LDTX20260908T074042.029.ldtxrecord` finalized,
passed strict CLI verification, and remuxed successfully. Elgato disconnected
at 07:40:53 and the video subscription returned at 07:43:12; the user confirmed
audible recovery. The Elgato decoded RMS was approximately 0.06793 before loss
(2–8 seconds), exactly zero throughout the checked missing-input window
(25–125 seconds), and 0.07358 after recovery (165–185 seconds).
Every AAC payload matched after remux: 9,554 Main Mix packets, 9,563 Elgato
packets, and 9,564 packets each for Webcam and HyperX. Per-track timestamp-shift
variation was exactly zero. The Main Mix's first remuxed packet PTS and its
manifest source-start value both equal 16,174,625 nanoseconds. Full-track
decoding of the remuxed MP4 completed with an empty error log using a fine
video output time base. This validates the connected/disconnected/recovered
sequence; it is not a claim of content synchronization between devices.
