<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# LDTX recording packages

An `.ldtxrecord` file is a directory package containing one or both fixed Canvas
fMP4 files and every configured Input Device audio track as an independent fMP4 stream.

## Physical format

Each single-file fMP4 consists of one initialization section followed by media
fragments in recording order:

```text
ftyp + moov + moof/mdat + moof/mdat + ...
```

Single-file fMP4 remains the source of truth after normal or interrupted
termination. LDTX uses one file per track because it is easier for users and
existing media tools to copy, inspect, and process than a split-file layout.

`manifest.mpd` is the static MPEG-DASH timing and byte-range index. Its
`presentationTimeOffset` maps each Representation's native media timeline onto
the Period timeline without rewriting fMP4 timestamps. A recording can be remuxed
without parsing LDTX protobuf metadata.

## Version 3 layout

New recordings use format version 3. Readers retain version 2 compatibility.
Version 3 stores each enabled Canvas's H.264 video and independent AAC-LC mix in
its own fragmented MP4. At least one Canvas must be enabled, and output cannot
start unless both Landscape and Portrait Programs have a non-empty Audio Mix.
This validation is independent of `recordsLandscape` and `recordsPortrait`:
disabling a Canvas recording file does not disable that Canvas runtime or waive
its Audio Mix requirement. Start remains available, but accepting Start with an
empty Mix is a hard validation failure displayed in an error dialog.
The built-in `silentAudio` channel is presented as **Dummy Audio Source (Silence)**. It emits
zero-valued PCM continuously from a host-clock presentation-time anchor, so it can satisfy this
requirement without opening a physical capture device.
The `.fragmented.mp4` suffix is intentional: normal finalization
does not flatten, replace, or rename the durable recording file.

- `Info.plist`: package identity and file-placement information only.
- `manifest.mpd`: presentation timing and fMP4 fragment byte ranges.
- `README.md`: locations of the remux-capable executables and a pointer to their
  current `--help` usage information.
- `landscape.fragmented.mp4`: optional Landscape H.264 video and Landscape AAC-LC mix.
- `portrait.fragmented.mp4`: optional Portrait H.264 video and Portrait AAC-LC mix.
- `InputDevices/<percent-encoded Input Devices name>.m4a`: each configured
  input audio track.
- Optional `Markers/HH-MM-SS.mmm.txt`: UTF-8 user-authored marker notes. The
  filename is the recording timecode; the UI presents the equivalent
  `HH:MM:SS.mmm` form.
- Optional `Diagnostics/events.jsonl`: privacy-limited recording lifecycle
  events used to correlate the recording with the separate application load
  database. Each complete line contains only `timestamp_unix_ms`, the
  per-launch random `launch_id`, `uptime_ms`, and a fixed event `kind`. Readers
  ignore an incomplete final line after an interrupted recording.
- `.finalized`: zero-byte completion marker, created last after every media
  writer, `manifest.mpd`, and `Info.plist` have been finalized successfully.
- Optional protobuf metadata and derived artifacts not required for remuxing.

The diagnostics event kinds are `recording_started`, `output_started`,
`output_stopped`, `output_reconstruction_requested`, `normal_completion`, and
`abnormal_stop`. The event log does not contain paths, Program or device names,
YouTube identifiers, free-form messages, or error descriptions. It is advisory:
missing events never change recording verification or recovery behavior.
`timestamp_unix_ms` is UTC Unix time for comparison with the application load
database. `uptime_ms` is elapsed monotonic time since that LDTX app launch.

If `.finalized` is absent, the package may still be recording, may have been
interrupted, or may predate the marker. Its contents can be inspected, but
completion is not guaranteed. The marker is never used to store metadata.
After it is created, the recording media, manifest, `Info.plist`, and
`.finalized` marker must not be modified. User-authored files under `Markers/`
may be added after finalization and are not required for verification,
playback, or remuxing.

`Info.plist` contains these stable keys:

| Key | Type | Meaning |
| --- | --- | --- |
| `LDTXRecordingFormatVersion` | Integer | Package format version, currently `3`. |
| `LDTXRecordingIdentifier` | String | Recording identifier. |
| `LDTXRecordingManifestFile` | String | Advisory static MPEG-DASH manifest path for external tools. |
| `LDTXRecordingLandscapeMediaFile` | String | Optional Landscape Canvas fMP4 path. |
| `LDTXRecordingPortraitMediaFile` | String | Optional Portrait Canvas fMP4 path. |
| `LDTXRecordingAudioTracks` | Array | Every independently recorded Input Device audio track. |

Each audio-track dictionary contains `Identifier`, `Name`, and `MediaFile`.
Timing, offsets, codecs, and fragment ranges belong to `manifest.mpd`, not
`Info.plist`. The manifest path is fixed as `manifest.mpd` by the recording
format and is also advertised in `Info.plist` so the package is self-describing
to external tools. LDTX uses the fixed format path rather than treating this
advisory value as an override. Existing key meanings and types stay stable
within a format version; readers must tolerate new optional keys.

## MPEG-DASH timing semantics

The normative format target is ISO/IEC 23009-1:2022. For each Representation,
the presentation time in its Period is:

```text
media sample presentation time - presentationTimeOffset + Period start
```

The `SegmentTimeline` uses the native media timeline. Large valid timestamps are
preserved; they are not normalized merely to accommodate a particular player.
Readers are expected to implement the DASH presentation-time mapping. Player
compatibility is useful test coverage but does not define the package format.

LDTX passes compressed video samples through without changing their payload.
At recording start, one common session origin is subtracted from every track's
PTS and valid DTS. This keeps all media timestamps close to zero while preserving
the exact relative offsets between tracks. Audio capture is PCM and must be
encoded for the MP4 recording.
Captured PCM is normalized to the recording format and encoded separately from
the MP4 muxer. A continuous sample-count clock is used internally by the AAC
converter; frame-to-source-PTS anchors restore recording timing in the persisted
audio fragments. Source-clock drift does not cause insertion or removal of PCM
samples merely to satisfy the encoder's continuity checks. Missing input still
produces silence. Persisted audio timing and manifest ticks have 1 ns resolution.
MPD metadata describes the resulting normalized timelines. All Representations
use a common presentation origin so that their relative starting offsets remain
explicit in the DASH timeline. Optional protobuf metadata may retain the original
host-clock origin when absolute capture diagnostics require it.

A multiplexed video/audio Representation may contain a `SupplementalProperty`
with `schemeIdUri="urn:tokyo.kaito.ldtx:audio-presentation-start-ns"`. Its `value`
is a signed decimal integer giving the first Main Mix PCM PTS, after subtraction
of the session origin, in nanoseconds. It is independent of the video's first
PTS and is not an AAC priming-packet timestamp. The value specifies recording
time directly; do not apply the video's `presentationTimeOffset` to it again.
LDTX uses this optional value when positioning embedded Main Mix audio during
remux, since a platform asset reader may round or normalize its fractional start.
When absent in older packages, the native audio track start remains the fallback;
the video manifest start must not be substituted for the audio start.

## Other media tools

Tools such as FFmpeg can open the fMP4 tracks independently without DASH input
support:

```sh
ffmpeg \
  -i landscape.fragmented.mp4 \
  -i InputDevices/GC%20Neo%20Audio.m4a \
  -map 0:v:0 -map 0:a:0 -map 1:a:0 \
  -c copy recording.mkv
```

Matroska is a useful archival output for arbitrary named audio tracks. MP4 can
be used when its codecs and track layout are supported by downstream players.

The canonical macOS content type is `tokyo.kaito.ldtx.record`. The former
`tokyo.kaito.ldtx.recording` type remains an imported compatibility alias for
existing Launch Services registrations. New package metadata uses the canonical
identifier; existing package metadata remains readable without migration.
