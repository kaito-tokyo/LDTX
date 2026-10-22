<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Captured input color normalization

CapturedInputNormalizer runs before background removal and composition, on the
Program renderer's serialized background executor. Camera capture does not
change its device format to satisfy a canvas's size, cadence, or color space.
The normalized canvas input is SDR BT.709, full-range, 8-bit NV12. The original
sample PTS, capture-session UUID and sequence number survive conversion.

## Conversion paths

| Input color information | Handling |
| --- | --- |
| 8-bit NV12, BT.709 primaries/transfer/matrix, no overriding profile | Keep the original buffer. Both 420v and 420f retain their range and use the existing Metal path. |
| BT.601 or SMPTE 240M YCbCr matrix | Core Image decodes the declared matrix and range, then renders BT.709 NV12. |
| BT.709, sRGB, BT.2020 SDR transfer and platform-resolvable primaries (including SMPTE-C, EBU, P3) | Core Video synthesizes the source RGB color space; Core Image/ColorSync performs gamut and transfer conversion. |
| SMPTE 240M transfer | A small static 32³ separable LUT applies the SMPTE 240M inverse transfer followed by the BT.709 transfer through Apple's color-cube filter. Other transforms remain platform operations. This avoids macOS's 709-like synthesized 240M curve. |
| RGB ICC profile or explicit CGColorSpace | Use the declared profile through ColorSync, rather than infer its gamut from another tag. Conflicting HDR profile/transfer tags fail that input. |
| PQ / HLG | Explicit HDR-to-SDR mapping described below, followed by BT.709 output conversion. |
| Unknown/malformed tags, unsupported combinations, Apple Log | Mark only that input unavailable. Do not reinterpret an unknown tag as BT.709. |

Input pixel layouts implemented here are 8-bit NV12 (420v/420f), BGRA, and 10-bit
bi-planar 4:2:0 (video/full range). Other packed YUV, RGB float, compressed and
vendor-specific layouts are not claimed as supported. Even a recognized color
tag is unavailable if Core Video cannot construct a matching color space or
Core Image cannot render that combination.

Metadata comes from the pixel-buffer attachments. Missing NV12 tags retain the
legacy BT.709 defaults; missing BGRA transfer defaults to sRGB. An explicit gamma
with no transfer uses the UseGamma path. These are defaults for absent metadata,
not replacements for explicit tags. When conversion needs a missing YCbCr matrix,
a private buffer carries the 709 default; the original buffer is untouched.
Range overrides are applied before converting non-canonical inputs, and are not
applied again to the resulting full-range frame. Canonical inputs keep the
existing range path. A necessary metadata/range preparation copy uses Metal
plane blits for IOSurface inputs; CPU-backed inputs use a bulk plane copy without
channel shuffling. A different view of the same IOSurface is deliberately not
retagged, because Core Video shares its color attachments with the original.
Format-description-only color metadata is not substituted for pixel-buffer tags;
GCNeo's real frame attachments still need separate authorized hardware validation.

## HDR policy

PQ and HLG are decoded into extended linear BT.2020 working space. Core Image's
[CIToneMapHeadroom](https://developer.apple.com/documentation/coreimage/citonemapheadroom)
then compresses the source headroom to **1.0 (SDR)**. Source headroom is fixed at
**10000/203 for PQ** and **1000/203 for HLG**: the PQ code range and a nominal
1000-nit HLG display, relative to 203-nit reference white. It does not follow the
current monitor's EDR headroom or adapt exposure per frame. This is an SDR output
policy, not preservation of HDR or a mastering-display preview. Source MaxCLL and
mastering metadata do not alter this fixed policy. Out-of-gamut results are
bounded by the final SDR output conversion; highlights are tone mapped, rather
than simply clipped at SDR white. Numeric tests cover shadow/mid-gray/highlight
ramps and 10-bit YUV decoding. The system tone curve can vary with macOS.

The image-import option toneMapHDRtoSDR alone did not preserve PQ highlight
differences in the synthetic CVPixelBuffer probe, so this path uses the explicit
filter and checks its output before rendering.

## Isolation and lifetime

One GPU CIContext and reusable pixel-buffer pools serve each Program input
pipeline. The latest normalized result is cached per input/session/sequence;
repeated canvas frames do not reconvert the same capture frame. Pools allocate a
new buffer while an earlier consumer retains its frame. Conversion waits on the
CIRenderTask before publishing or releasing its source/destination. The compositor
also retains source CVPixelBuffers and CVMetalTexture wrappers through command
completion. Encoding failures submit no compositor work.

Normalization failure removes that input from the available source map, allowing
other cameras, dummy-input rendering and overlays to continue. Diagnostics log
once on failure per input until recovery or pipeline rebuild, then log recovery.
Repeated failure/recovery episodes are limited to one announced failure per
input per ten seconds; they do not log every rejected frame. BGRA is normalized to real two-plane NV12
before entering the actual background-removal preprocessor, not merely combined
with an artificial test mask in the compositor.
