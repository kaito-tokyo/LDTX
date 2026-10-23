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

## Dynamic Text

Workspace edits support **Edit → Undo / Redo** and **Command-Z / Shift-Command-Z**
while output is idle. Macro text and variable edits share Workspace's history.

Add **Dynamic Text** under **Video Components**, then enter text and use
the text editor's **Insert Variable** context menu to insert a Vision's OCR text,
classification label,
or confidence. Save the Workspace to apply the component to preview and output.
Variable values update automatically as Vision results arrive. Variables appear
as inline chips; click one to choose a replacement or remove it. Arrow keys,
selection, and deletion use the native text editor; Undo/Redo uses Workspace's
history. RTFD copying preserves formatting and variable attachments; RTF and
plain-text export represent variables as `{{id/sel}}`. Ordinary pasted text stays
literal. Missing variables render empty and retain their references for editing.
Unicode and multiline text are supported. Content is stored exclusively as valid
RTFD bytes in `rtfd_document`; earlier XML and token documents are unsupported.
See [Dynamic Text persistence](docs/dynamic-text.md) for the format details.
Width and height are relative to the Landscape Canvas; layer transforms control
placement. Text wraps at its authored font sizes and clips to this extent,
using a transparent background.

## Screenshots

The Workspace toolbar and Stream Deck share Stop Output, Start/Pause Output,
Capture Screenshot(s), and Show Recording in Finder actions. Sidebar and Inspector
toggles and Run Inference remain toolbar-only editing controls.

After screenshots are saved, LDTX requests notification permission on first use
and sends one silent macOS notification per capture, with the Landscape Program
screenshot attached as its image preview when available and the capture timestamp
as its body. Click the notification to
select the saved images in Finder. Denying notifications does not prevent saving;
notification display follows macOS notification settings and Focus. Both toolbar
and Stream Deck captures use OS notifications without a result popover.

Screenshot conversion, JPEG encoding, and file writes run on a serialized background
queue after the current frames and destinations are captured. One active capture
and one waiting capture are allowed per Workspace; further requests report that
saving is busy. Completion notifications follow successful writes. A failure in
either the global save or the recording-package copy rolls back that capture set.
Package copies require active recording with an accepted video frame. Pause and
Stop close package-copy admission and wait for this session's accepted package
copies before finalizing. Closing a Workspace waits for all of its accepted
captures. Save errors that finish during closing are retained for application-level
error presentation. Global screenshots remain available in every output state.

## Cut Recording

Choose **Cut Recording** in the Workspace toolbar during local recording to
finish the current `.ldtxrecord` package and continue in a replacement package.
Landscape and Portrait wait for usable video boundaries; mixed and input audio
are divided at those boundaries. YouTube output continues on its existing
subscriptions. Cut is disabled until the recording has accepted video and audio,
and while a cut is pending. A replacement preparation failure keeps the current
recording active and reports the error. Replacement first-video preparation has
an independent 10-second deadline. A stalled replacement is left incomplete;
rollback and later cuts do not wait for its writer to return. An uninterruptible
native call retains its worker and replacement resources until it returns.
Stop and Pause cancel a waiting cut and
drain any already committed package transition. Close still requires output to
be stopped first; an admitted Close supersedes a Cut waiting in the command queue.

Manual OCR results captured before a package change still update the Inspector
and variables, but are not archived into the replacement package. Archived OCR
timestamps refer to the timeline captured when requesting the analyzed frame. Package archive
admission pauses while the replacement boundary is being prepared.

## Manual OCR

Select an OCR Vision and choose **Run** in its **Recognition Result** section.
Run uses the last successfully saved configuration and remains available during
local recording while configuration editing is locked. Repeated requests for the
same OCR are ignored while it is running. Results and errors appear in the
Inspector; successful results also update Dynamic Text variables and use the
existing recording-package archive when the same recording is still active.
Save new OCR Visions before running them.

## Clock

Clock uses **Font Size** in Landscape Canvas pixels (48 by default for new
components). The same pixel size applies on the Portrait Canvas. The renderer
derives a stable text extent from the bundled font metrics and the enabled date
and time fields; layer Scale X/Y scale the resulting image.

The Clock inspector supports up to two text outlines in back-to-front order,
with opacity-aware colors and widths in output Canvas pixels. Add or remove an
outline in **Text Outlines**. New widths must be between 0 and 64 pixels,
including zero. Invalid editing drafts leave the last accepted width unchanged.
Older saved widths above 64 remain intact and display a rendering-limit notice;
the renderer continues to cap them at 64 pixels. Outline edits use Workspace
Undo/Redo and are disabled during output. Clock has a transparent background; its former
background-color fields are reserved and have no editor.

Clock's former `width` and `height` Protobuf fields are reserved. Older V4 Clocks
without `font_size` automatically import at 48 pixels, preserving the reserved
geometry as unknown data. Reading does not rewrite the package; the new font
size is stored on the next save.

## Vision Programmer

Open **LDTX → Vision Programmer…** to train an LDTX Scene Detector. Choose a folder
containing one subfolder per class, set the maximum iteration count (25 by default),
then select **Start training**. Training uses Image Feature Print V2 with aspect-ratio-preserving
scale-to-fit, no augmentation, and a fixed 95% training / 5% validation split using
Create ML Components' `randomSplit`.
When training completes, the progress sheet closes and the standard file exporter
opens to save the `.mlpackage`.
For standalone testing, run the `LDTXVisionProgrammerApp` scheme in Xcode.

## Internal Framework Modules

This table lists the non-test library targets declared in `project.yml` and generated
as dynamic Xcode frameworks. External libraries remain Xcode-managed Swift packages.

| Module                     | Description                                                        |
| -------------------------- | ------------------------------------------------------------------ |
| LDTXApp                   | Application lifecycle, Workspace orchestration, UI, and output coordination. |
| LDTXAudioEngine            | Workspace-owned C++ HAL input, monitoring, timed mixing and PCM output. |
| LDTXBackgroundSegmentation | Background-removal model loading and compatibility checks.         |
| LDTXCapture                | AVCapture camera sources, services, and capture-session management. |
| LDTXDeviceRegistry         | Workspace device discovery using AVCapture cameras and Core Audio input UIDs. |
| LDTXDash                   | DASH manifest, ingest endpoint, upload, and local-file pipeline.   |
| LDTXFontRasterizer         | C-backed TrueType glyph rasterization used by runtime overlays.    |
| LDTXInternalProtocols      | Internal interfaces shared across optional feature boundaries.     |
| LDTXMediaTiming            | Audio timeline and presentation-timestamp clock utilities.         |
| LDTXMP4                    | Segmented MP4 writing and audio/video sample normalization.        |
| LDTXProgram                | Program runtime definitions and output profiles.                           |
| LDTXProtos                 | SwiftProtobuf messages and Workspace integrity validation. |
| LDTXProtosMacOSExtra       | macOS-specific extensions for Protobuf values, including AppKit color conversion. |
| LDTXWorkspaceBundleFormat  | Workspace bundle values, `.ldtxworkspace` package IO, and on-disk format validation. |
| LDTXProgramRendering       | Translation from Program definitions to renderable compositions.   |
| LDTXProgramRuntime         | Runtime services for preview, capture, recording, and streaming.   |
| LDTXRecordPlayerApplet      | Recording playback windows, pane UI, and marker persistence.       |
| LDTXRecordBundleFormat | Recording bundle structure, metadata IO, and DASH timing parsing. |
| LDTXRecording              | Media-track validation, playback composition, and remux.     |
| LDTXTaskQueue              | Workspace event sequencing and Session-scoped task flow.           |
| LDTXUtils                  | Command-line utilities shared by the LDTX helper tool.            |
| LDTXVariableMacro          | Variable Macro text editor and insertion UI.                      |
| LDTXRichText          | macOS RTFD persistence, variable attachment validation, and rich-text expansion. |
| LDTXVideoComposition       | Shared video composition model used by renderers and runtimes.     |
| LDTXVideoRendering         | Metal-backed video compositing, shader loading, and render output. |
| LDTXVisionProgrammerApplet | Vision Programmer windows and training UI. |
| LDTXVisionTraining | Scene detector training and Core ML model export using Create ML Components. |
| LDTXVision                 | On-device OCR and classical computer-vision processing.            |
| LDTXWorkspaceAppletModel    | Workspace app models and runtime configuration values.           |
| LDTXWorkspaceAppletStore    | Active Workspace bundle state and application preferences.       |
| LDTXWorkspaceAppletService  | Workspace runtime coordination and stateless feature services.   |
| LDTXWorkspaceAppletController | SwiftUI Workspace document connections and runtime lifecycle.         |
| LDTXWorkspaceAppletUI       | Observable Workspace document, SwiftUI interface, Metal bridges, and local app data. |
| LDTXYouTube                | YouTube Live API models and client.                                |
| LDTXYouTubeAuth            | Google OAuth and AppAuth-backed YouTube authorization.             |
| LDTXYouTubeOutputProtocol  | Protobuf messages and sequencing utilities for YouTube output IPC. |
| LDTXYouTubeRTMPS           | YouTube-specific secure RTMP publishing and dual-output coordination. |

Linux-compatible modules are maintained under `Sources/Corelibs`. XcodeGen and
SwiftPM build the same sources independently; see the [Corelibs build guide](docs/build.md#corelibs)
for Docker verification and test placement.

See [`docs/ldtxrecord.md`](docs/ldtxrecord.md) for the stable recording-package
layout, MPEG-DASH timing model, and remux requirements.

See [`docs/appkit-ui.md`](docs/appkit-ui.md) for application and pane ownership,
and [`docs/ui-rules.md`](docs/ui-rules.md) for UI behavior rules.
See [`docs/preview-accessibility.md`](docs/preview-accessibility.md) for preview
image retrieval through the `AXImageData` accessibility attribute.
