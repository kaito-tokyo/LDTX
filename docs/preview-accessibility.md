<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
SPDX-License-Identifier: Apache-2.0
-->

# Preview image accessibility

The Workspace's `canvasPairPreview` AX image exposes `AXImageDataSize` and the
parameterized `AXImageData` attribute. It retains the Landscape and Portrait
selection custom actions. The element is an AppKit-owned child of the preview
host, rather than a SwiftUI aggregate that hides the parameterized attributes.

This implements the existing [WebKit RGBA contract](https://github.com/WebKit/WebKit/commit/69bb8cb9c0309011f88a5736dd5fb4e4f83f75fe).
The attribute names are not declared in the public AppKit SDK used here; this
does not establish a publicly supported AppKit image API. Automatic requests by
VoiceOver or other assistive tools have not been verified.

## Requests

Use `AXUIElementCopyAttributeValue(element, CFSTR("AXImageDataSize"), ...)`
to obtain an AXValue containing the completed preview's pixel dimensions.
Use `AXUIElementCopyParameterizedAttributeValue` with `AXImageData` and a
dictionary containing:

| Key | Value |
| --- | --- |
| AXImageDataFormat | Required string `RGBA` |
| AXImageDataResizeWidth / AXImageDataResizeHeight | Optional nonnegative integers; zero/absent uses the corresponding native dimension |
| AXImageDataLeft / AXImageDataTop | Optional top-left extraction origin in resized pixels |
| AXImageDataWidth / AXImageDataHeight | Optional extraction dimensions; both must be positive to select a subrect |

The result is CFData/NSData with tightly packed, top-first, unpremultiplied
sRGB RGBA8 bytes. No PNG encoding or screen capture occurs in the app.
The whole resized image is capped at 4,000,000 pixels, preserving the requested
aspect ratio when capped. Dimensions must be finite integers in 0...16384;
Boolean, negative, fractional and invalidly typed values are rejected.
Extraction rectangles exceeding 4,000,000 pixels are rejected. Parts outside
the resized image are transparent zero bytes.

Before the first successful render, size is zero and no image is available.
The returned image is the latest completed readback; it can lag a frame behind
presentation. Size and data are separate requests and can span a window resize.
Stopping the preview clears the snapshot and invalidates pending publication.
Detached elements do not return image data.

## Rendering and cost

`ProgramPairPreviewRenderer` copies the actual composed BGRA drawable into a
shared Metal buffer in the same command buffer, before presentation. This
includes both canvases, color preference, loading placeholders and transparent
gap. GPU completion owns the readback buffer until a serialized worker copies
it into an immutable CGImage. One readback is allowed in flight; intervening
renders skip capture rather than queueing more work. Native drawables over
16,000,000 pixels are not captured. The cache does not retain a drawable.

Image resizing, extraction and alpha conversion execute on the worker queue.
AX requests are synchronous, so the caller waits for conversion to finish.
Continuous readback adds a GPU copy and CPU memory copy per captured preview
frame; production workload performance has not yet been benchmarked. No
recording or streaming pipeline is changed.

## Validation (2026-10-18)

- LDTXApp Debug build, with code signing disabled.
- `PreviewAccessibilityImageIntegrationTestSuite`: actual Metal BGRA readback,
  row orientation, straight alpha, crop zero-fill, malformed inputs and limits.
- `AppUIComponentTestSuite.PreviewImageAccessibilityUnitTestSuite`: identity,
  parameter advertisement and both selection custom actions.
- Independent process using the production `ProgramCanvasPairedPreview` and
  `PreviewImageAccessibilityElement` inside an NSHostingView, with a synthetic
  Metal delegate: external client found `canvasPairPreview`, enumerated
  `AXImageData`, read native size 592×252, and retrieved 8×4 RGBA (128 bytes),
  with every pixel matching the red test frame. The probe was closed afterward.
  The running LDTX process was not modified or restarted.

The temporary cross-process probe sources and output are
`/tmp/ldtx-ax-preview-probe.swift`, `/tmp/ldtx-ax-preview-client.swift` and
`/tmp/ldtx-ax-preview.rgba`. Actual game content in the running LDTX and
automatic assistive-tool image requests remain untested.
