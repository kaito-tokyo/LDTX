<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Rendering Pipeline Data Formats

This document defines the media formats at the boundaries between Program
rendering, live output, recording, and DASH delivery. The initial output
profile is `sdr-1080p60`.

## Video

- **Program renderer output:** NV12 (`420YpCbCr8BiPlanarFullRange`), 8-bit
  4:2:0. The Metal compositor renders Program frames in full range so it can
  preserve the renderer's RGB-domain output without a separate conversion pass.
- **Encoder input:** `VTCompressionSession` accepts the renderer's full-range
  NV12 buffers. Pixel-buffer range is an input representation, not a H.264
  stream requirement. VideoToolbox is responsible for any conversion required
  by the encoder's requested source-pixel-buffer attributes.
- **Encoded stream:** H.264 High@L4.2, 1920×1080 at 60 fps, constant bit rate
  of 6,000,000 bit/s, Rec.709 primaries/transfer/matrix, 8-bit 4:2:0,
  **video range**, closed GOP of 120 frames (2 seconds), no B-frames, and no
  open GOP. The actual SPS/PPS and codec string are the source of truth and
  must be verified before publishing initialization or media segments.
- **Container and delivery:** fragmented MP4 initialization/media segments,
  DASH segments of 2 seconds, and the recording manifest all use the verified
  stream codec and color description. A single encoded video sample stream is
  fan-out input for both recording and YouTube/DASH output.

## Audio

- **Program mix:** Linear PCM, interleaved Float32, 48,000 Hz, stereo. Input
  devices with other formats are normalized before they enter the Program mix.
- **Encoder input:** timestamped normalized PCM sample buffers. Audio PTS must
  be continuous; discontinuities are output-session errors rather than silently
  retimed samples.
- **Encoded stream:** AAC-LC, 48,000 Hz, stereo, 128,000 bit/s.
- **Container and delivery:** the same encoded AAC sample stream is muxed with
  the H.264 stream for fragmented MP4/DASH and recorded output. Audio/video
  timing follows the output session's shared timeline.
