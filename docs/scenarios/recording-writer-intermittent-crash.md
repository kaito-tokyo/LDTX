<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Recording writer crash and source-clock validation

## Status

The historical CoreMedia/MediaToolbox crash was independently reproduced, and
the AAC-passthrough workaround is implemented. The source-clock implementation is
committed, signed, and DCO-signed in `1eaaa13`; this report is updated by
`b572613`. Issue [#246](https://github.com/kaito-tokyo/LDTX/issues/246) remains
open because Apple's internal fault and its equivalence to the original report
are not proven.

The current implementation passed unit, integration, stress, and physical
hotplug validation for the tested configurations. These results do not prove
that every historical framework crash is eliminated.

## Historical crash investigation

Issue #246 reported an intermittent crash in the combined recording test suite,
with CoreMedia deferred-notification frames such as `CFArrayGetCount` and
`__CF_IS_OBJC`. An earlier cut-recording issue (#176) involved a different
`CFDictionaryGetCount` frame family. Similar symbols do not establish a common
root cause.

The original investigation reproduced both SIGTRAP and SIGSEGV in LDTX tests,
then in a standalone executable using only AVFoundation. The crash did not
require remux, asset inspection, input loss, multiple concurrent recordings, or
a nonzero first PTS. Passing an isolated control was not evidence that the
writer was safe. The attempted `.indefinite` segment interval was rejected by
AVFoundation (`-11875`) and was not a valid control; a valid 10-second interval
was used instead.

## Production lifecycle coverage

The stress coverage in `AudioSideStreamSegmentPipelineHardTests` exercises
production recording components:

- `concurrentRecordingRemuxLifecycleStress`
- `concurrentRecordingWithoutRemuxLifecycleStress`
- `mainWriterOnlyLifecycleStress`
- `pcmWriterOnlyLifecycleStress`
- `aacPassthroughAssetWriterLifecycleStress`

The Hard suite runs each stress control with 30 rounds, one worker, continuous
input, and no retained recorder objects. The ordinary Hard tests separately
cover intermediate/tail loss and no input from startup.

## Recording timing policy

Input PCM PTS is authoritative for recording sample placement. The recording
clock subtracts one fixed origin and preserves the mapping between source time
and stored time. The AAC converter's continuous sample-count clock is an
internal encoding constraint; its drift must not insert or remove source PCM
samples. Missing input is represented by silence.

Streaming keeps its independent output clock. LDTX guarantees timeline
continuity, not synchronization between independently generated device signals.
PTS and DTS remain distinct. Stored timing and manifest ticks have 1 ns
resolution; this is finite storage precision, not unlimited rational precision.

AAC priming is separate from source placement. The converter origin rounds down
to avoid mapping a muxer's zero-clipped priming boundary to a negative source
time. Source anchors retain fractional input PTS. Fragment rewriting changes
the audio track timescale, decode base time, and packet durations while keeping
AAC payloads and video bytes unchanged. Fragment data offsets are adjusted when
the rewritten header size changes. Emitted anchor history is bounded and safely
discarded only after successful fragment delivery.

The manifest uses nanosecond `SegmentTimeline` ticks. Embedded Main Mix start is
recorded independently using:

```text
urn:tokyo.kaito.ldtx:audio-presentation-start-ns
```

This optional `SupplementalProperty` contains the signed nanosecond start of
the Main Mix after session-origin subtraction. It must not inherit the video's
start offset. Older packages without the property use the native audio track
start as fallback.

## Automated validation

The final full run passed **564 tests in 72 suites**, with one explicitly
skipped opt-in test and zero failures. Swift-format strict lint and
`git diff --check` passed.

Coverage includes positive and negative clock drift, Main Mix and individual
inputs, missing input and silence, format conversion, bounded anchor retention,
fragment payload/offset preservation, and malformed timing-box handling.

Fractional-start integration cases of 1 ns, 20,000 ns, and 20,123 ns pass from
package creation through verification and remux. Main Mix cases of 1 ns,
18,500 ns, and 20,123 ns pass without applying the video manifest offset.

The corrected implementation also passed 30 groups of six concurrent
recording/remux lifecycles (180 recordings), mixing continuous input,
intermediate/tail loss, and no-input startup. Evidence:

`/private/tmp/ldtx-source-clock-mixed-remux-stress.log`

## Physical validation

The connected-device recording
`LDTX20260908T074042.029.ldtxrecord` finalized successfully with Elgato,
HyperX, and mono HD Webcam input. Strict CLI verification, remux, and complete
track decoding succeeded. Elgato was disconnected at 07:40:53 and its video
subscription returned at 07:43:12; the user confirmed audible recovery.

The Elgato decoded RMS was approximately 0.06793 before loss, exactly zero in
the checked missing-input interval, and 0.07358 after recovery. AAC payloads
were identical before and after remux: 9,554 Main Mix packets, 9,563 Elgato
packets, and 9,564 packets each for Webcam and HyperX. Timestamp-shift
variation was zero for every track. The Main Mix first remuxed packet and its
manifest source-start value were both 16,174,625 ns.

An earlier 66-second capture (`LDTX20260908T070448.661.ldtxrecord`) failed to
finalize because the mono Webcam file contained initialization data only. It
is retained as a historical failure and is not evidence against the corrected
revision.

## Limits and follow-up

The tests do not establish Apple's internal crash root cause, guarantee that
other AVFoundation configurations cannot fail, or measure content
synchronization between devices. The physical sequence validated connected,
disconnected, silent, and recovered recording continuity; it did not attempt
to align user-generated signals across devices.

Issue #246 should remain open until the project maintainer decides whether the
independent framework reproducer and the workaround warrant an upstream report.
No release, tag, or push is performed by this investigation.

Historical temporary artifacts are not repository fixtures and may no longer
exist.
