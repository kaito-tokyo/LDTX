<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# LDTX recording packages

An `.ldtxrecord` file is a directory package containing the complete main video
and every configured audio track as independent single-file fMP4 streams.

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

## Version 2 layout

New recordings use format version 2. Readers continue to accept version 1
packages. Version 2 permits a logical track to resume in a new generation file
after an isolated recording-writer interruption. The first generation keeps the
version 1 name; later generations add `~N` before `.mp4`, for example
`output-video~2.mp4`. Each recovery boundary starts a new DASH Period so gaps
remain explicit without rewriting native media timestamps.

The `.finalized` marker means that the package coordinator finished the durable
track ledger, `manifest.mpd`, and `Info.plist`. It does not assert that every
configured track was continuously available. Missing generations and gaps are
represented by the manifest and do not prevent package finalization.

## Package layout

- `Info.plist`: package identity and file-placement information only.
- `manifest.mpd`: presentation timing and fMP4 fragment byte ranges.
- `README.md`: locations of the remux-capable executables and a pointer to their
  current `--help` usage information.
- `output-video.mp4`: main video as single-file fMP4.
- `output-audio.mp4`: independently stored Program output mix.
- `InputDevices/<percent-encoded Input Devices name>.mp4`: each configured
  input audio track.
- Optional `Markers/HH-MM-SS.mmm.txt`: UTF-8 user-authored marker notes. The
  filename is the recording timecode; the UI presents the equivalent
  `HH:MM:SS.mmm` form.
- Optional `Diagnostics/events.jsonl`: privacy-limited recording lifecycle
  events used to correlate the recording with the separate application load
  database. Each complete line contains only `timestamp_unix_ms`, the
  per-launch random `launch_id`, `uptime_ms`, and a fixed event `kind`. Readers
  ignore an incomplete final line after an interrupted recording.
- `.finalized`: zero-byte completion marker, created last after the durable media
  ledger, `manifest.mpd`, and `Info.plist` have been finalized successfully.
- Optional `.shield.json`: a Recording Shield v1 integrity statement, created
  only by an explicit seal operation after normal finalization.
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

## Recording Shield v1

Recording Shield is an integrity layer separate from media/manifest validation.
It lets an independent implementation detect missing, modified, unexpected, or
unsafe entries in a completed package. It does not initially assert a public
creator identity.

The root `.shield.json` is UTF-8 JSON encoding an in-toto Statement v1:

- `_type` is exactly `https://in-toto.io/Statement/v1`.
- `predicateType` is exactly `https://ldtx.dev/attestation/recording-shield/v1`.
- `subject` contains every covered regular file exactly once. `name` is its
  canonical relative path and `digest.sha256` is 64 lowercase hexadecimal
  digits. Subjects are ordered by the UTF-8 bytes of `name`.
- `predicate.profileVersion`, `packageRoot`, and `digestAlgorithm` are exactly
  `1.0`, `.`, and `sha256`.
- `predicate.pathPolicy`, `entryPolicy`, and `verificationPolicy` are exactly
  `utf8-nfc-relative-slash-v1`, `regular-files-no-follow-v1`, and
  `closed-world-v1`.

These policy values are versioned constants, not manifest-controlled extension
points. Paths are non-empty, relative, UTF-8/NFC strings using `/`. Leading or
trailing slashes, empty, `.` or `..` components, backslashes, NUL, and
absolute/volume prefixes are forbidden. NFC and Unicode case-fold collisions
are forbidden. Directories carry no digest and empty directories are ignored.
Symbolic links are never followed and are forbidden, as are sockets, FIFOs, and
device entries. Each regular hard-link path is hashed and listed separately.

Only root `.shield.json`, `.shield.dsse.json`, and `SHA256SUM` are excluded.
Nested entries with those names are covered, and `.finalized` is covered.
Verification is closed-world: every subject must exist as a regular file with a
matching SHA-256 digest, and every covered regular file must be listed. Verifiers
collect all detectable problems and identify their paths. No Shield, unreadable
data, unsupported profile/version, or I/O failure is `unverifiable`; content or
policy failures are `invalid`; otherwise the result is `valid`.

Sealing requires `.finalized`, never runs as part of abnormal StopToken cleanup,
and never silently replaces a Shield. Adding a Marker after sealing makes it
unexpected. `.shield.dsse.json` is reserved for a future DSSE envelope whose
`payloadType` is `application/vnd.in-toto+json` and whose payload is the exact
bytes of `.shield.json`; integrity and origin results remain separate. Optional
`SHA256SUM` is derived output, not authoritative. A transformation must not
overwrite a sealed source; its new attestation should refer to the source
statement and artifact digest.

`Info.plist` contains these stable keys:

| Key | Type | Meaning |
| --- | --- | --- |
| `LDTXRecordingFormatVersion` | Integer | Package format version, currently `1`. |
| `LDTXRecordingIdentifier` | String | Recording identifier. |
| `LDTXRecordingManifestFile` | String | Advisory static MPEG-DASH manifest path for external tools. |
| `LDTXRecordingMainMediaFile` | String | Main video single-file fMP4 path. |
| `LDTXRecordingAudioTracks` | Array | Every independently recorded audio track. |

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
Captured audio sample buffers and their source PTS are submitted directly to the
platform AAC writer; LDTX does not perform a separate normalization or resampling
step. Format conversion performed internally by the platform encoder is permitted.
MPD metadata describes the resulting normalized timelines. All Representations
use a common presentation origin so that their relative starting offsets remain
explicit in the DASH timeline. Optional protobuf metadata may retain the original
host-clock origin when absolute capture diagnostics require it.

## Other media tools

Tools such as FFmpeg can open the fMP4 tracks independently without DASH input
support:

```sh
ffmpeg \
  -i output-video.mp4 \
  -i output-audio.mp4 \
  -i InputDevices/GC%20Neo%20Audio.mp4 \
  -map 0:v:0 -map 1:a:0 -map 2:a:0 \
  -c copy recording.mkv
```

Matroska is a useful archival output for arbitrary named audio tracks. MP4 can
be used when its codecs and track layout are supported by downstream players.
