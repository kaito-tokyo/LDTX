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

## Version 1 layout

- `Info.plist`: package identity and file-placement information only.
- `manifest.mpd`: presentation timing and fMP4 fragment byte ranges.
- `output-video.mp4`: main video as single-file fMP4.
- `output-audio.mp4`: independently stored Program output mix.
- `InputDevices/<percent-encoded Input Devices name>.mp4`: each configured
  input audio track.
- `.finalized`: zero-byte completion marker, created last after every media
  writer, `manifest.mpd`, and `Info.plist` have been finalized successfully.
- Optional protobuf metadata and derived artifacts not required for remuxing.

If `.finalized` is absent, the package may still be recording, may have been
interrupted, or may predate the marker. Its contents can be inspected, but
completion is not guaranteed. The marker is never used to store metadata and
the package must not be modified after it is created.

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

## CLI and MCP

```sh
ldtx record inspect Recording.ldtxrecord
ldtx record verify Recording.ldtxrecord
ldtx record remux Recording.ldtxrecord
ldtx mcp
```

The app-bundled stdio MCP server is invoked as
`LDTX.app/Contents/Library/Helpers/LDTXHelper mcp`. Discovery metadata is in
`Contents/Resources/MCP`. Standard output is reserved for MCP messages and
diagnostics use standard error or unified logging.

By default, remux writes `Recording.mp4` next to `Recording.ldtxrecord` and
does not overwrite an existing output unless `--replace` is specified.
`verify` and `remux` attempt to recover a package without `.finalized` and emit
a warning. Pass `--strict` when an unfinalized package must be rejected. Remux uses compressed H.264/AAC
sample passthrough and writes a normal, fast-start MP4 with the main mix enabled
and every side track retained as an independent disabled-by-default audio track.

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
