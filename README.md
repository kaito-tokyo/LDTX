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

This table lists the non-test library targets declared in `Package.swift`. It excludes
the command-line executable target and the app and extension targets defined by Xcode.

| Module                     | Description                                                        |
| -------------------------- | ------------------------------------------------------------------ |
| LDTXAppCore                | Application lifecycle, Workspace orchestration, and output coordination. |
| LDTXAppUI                  | Shared Program editor, Workspace, settings, and preview UI.        |
| LDTXAudioEngine            | Low-level audio mixing engine.                                     |
| LDTXBackgroundSegmentation | Background-removal model loading and compatibility checks.         |
| LDTXCapture                | Camera capture sources, services, and capture-session management.  |
| LDTXDash                   | DASH manifest, ingest endpoint, upload, and local-file pipeline.   |
| LDTXDiagnostics            | Privacy-limited process-load sampling and SQLite queries.          |
| LDTXFontRasterizer         | C-backed TrueType glyph rasterization used by runtime overlays.    |
| LDTXFullAppFeatures        | Full-app feature bindings for vision and background removal.       |
| LDTXInternalProtocols      | Internal interfaces shared across optional feature boundaries.     |
| LDTXMediaTiming            | Audio timeline and presentation-timestamp clock utilities.         |
| LDTXMP4                    | Segmented MP4 writing and audio/video sample normalization.        |
| LDTXProgram                | Program definitions and protobuf-backed persistence codecs.        |
| LDTXProgramRendering       | Translation from Program definitions to renderable compositions.   |
| LDTXProgramRuntime         | Runtime services for preview, capture, recording, and streaming.   |
| LDTXRecordPlayerUI         | Reusable recording playback and annotation UI.                     |
| LDTXRecording              | Recording-package inspection, validation, playback, and remux.     |
| LDTXTaskQueue              | Workspace event sequencing and Session-scoped task flow.           |
| LDTXVideoComposition       | Shared video composition model used by renderers and runtimes.     |
| LDTXVideoRendering         | Metal-backed video compositing, shader loading, and render output. |
| LDTXVision                 | On-device vision-language model loading and inference with MLX.    |
| LDTXWorkspace              | Workspace definitions, defaults, package services, and storage.    |
| LDTXYouTube                | YouTube Live API models and client.                                |
| LDTXYouTubeAuth            | Google OAuth and AppAuth-backed YouTube authorization.             |
| LDTXYouTubeOutputProtocol  | Protobuf messages and sequencing utilities for YouTube output IPC. |

See [`docs/vlm-allocation-free.md`](docs/vlm-allocation-free.md) for the fixed-envelope,
allocation-free Qwen3-VL execution design and verification gates.

See [`docs/ldtxrecord.md`](docs/ldtxrecord.md) for the stable recording-package
layout, MPEG-DASH timing model, and remux requirements.
