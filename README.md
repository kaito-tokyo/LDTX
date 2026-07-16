<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# LDTX

LDTX lets users build a custom screen and send it to a live stream. That
custom screen is called a **Program**. LDTX also provides the **Program
Editor** for building user-defined Programs.

**A Program on LDTX can:**
- Output an input device or screen capture
- Place shapes, text, and images on it
- Remove the background from your portrait

## Swift Package Modules

| Module                     | Description                                                        |
| -------------------------- | ------------------------------------------------------------------ |
| LDTXAudioEngine            | Low-level audio mixing engine.                                     |
| LDTXAutomation             | XPC, JSON-RPC, and protobuf contracts for app automation.          |
| LDTXBackgroundSegmentation | Background-removal model loading and compatibility checks.         |
| LDTXCapture                | Camera capture sources, services, and capture-session management.  |
| LDTXDash                   | DASH manifest, ingest endpoint, upload, and local-file pipeline.   |
| LDTXMediaTiming            | Audio timeline and presentation-timestamp clock utilities.         |
| LDTXMP4                    | Segmented MP4 writing and audio/video sample normalization.        |
| LDTXProgram                | Program definitions and protobuf-backed persistence codecs.        |
| LDTXProgramRendering       | Translation from Program definitions to renderable compositions.   |
| LDTXProgramRuntime         | Runtime services for preview, capture, recording, and streaming.   |
| LDTXRecording              | Recording-package inspection, validation, playback, and remux.     |
| LDTXTaskQueue              | Event sequencing and background generation with cooperative stop.  |
| LDTXVideoComposition       | Shared video composition model used by renderers and runtimes.     |
| LDTXVideoRendering         | Metal-backed video compositing, shader loading, and render output. |
| LDTXVision                 | On-device vision-language model loading and inference with MLX.    |
| LDTXWorkspace              | Workspace definitions, defaults, package services, and storage.    |
| LDTXYouTube                | YouTube Live API models and client.                                |
| LDTXYouTubeAuth            | Google OAuth and AppAuth-backed YouTube authorization.             |

See [`docs/vlm-allocation-free.md`](docs/vlm-allocation-free.md) for the fixed-envelope,
allocation-free Qwen3-VL execution design and verification gates.

See [`docs/ldtxrecord.md`](docs/ldtxrecord.md) for the stable recording-package
layout, MPEG-DASH timing model, and remux requirements.
