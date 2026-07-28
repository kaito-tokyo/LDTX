<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Font assets

The default information-overlay font foundation is the unmodified Noto Sans
Latin/Greek/Cyrillic variable family from the official Noto project:

- Upstream project: <https://github.com/notofonts/latin-greek-cyrillic>
- Distribution index: <https://notofonts.github.io/latin-greek-cyrillic/>
- Upright family: `NotoSans[wght].ttf`
- Italic family: `NotoSans-Italic[wght].ttf`
- License and copyright: the upstream `OFL.txt`, bundled beside the fonts

The files were retrieved unmodified from the upstream `full/slim-variable-ttf`
HEAD build on 2026-07-28. The distribution page identified that build as
source commit [`cb097900c74b26e6dcab899b4f07b2bc79dd80c4`](https://github.com/notofonts/latin-greek-cyrillic/commit/cb097900c74b26e6dcab899b4f07b2bc79dd80c4).
They are not subsets. The exact distribution URLs were:

- <https://notofonts.github.io/latin-greek-cyrillic/fonts/NotoSans/full/slim-variable-ttf/NotoSans%5Bwght%5D.ttf>
- <https://notofonts.github.io/latin-greek-cyrillic/fonts/NotoSans/full/slim-variable-ttf/NotoSans-Italic%5Bwght%5D.ttf>

Recorded SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `NotoSans[wght].ttf` | `205aec8c4579688bc66506ca3c01d930a567634f1ddad3fa5c6fb91e0c3c1cd1` |
| `NotoSans-Italic[wght].ttf` | `a4f45c53480a0b04570af420fbbd674ebb9d61f7e3bb6bb2716cf0280c3f0201` |
| `OFL.txt` | `cee9892f9f0cc8fe882c9e9537ee6a89621d86ee7ceaf70b02e2b2b1c25c061a` |

`LDTXProgramRuntime` copies the directory as a SwiftPM resource bundle.
`NotoSansFontResources` is the single lookup point for the Metal glyph atlas
renderer. Clock renderer initialization reports a resource error if the
required upright font is absent.

## Glyph rasterizer

Clock uses the official `stb_truetype.h` from the `nothings/stb` project at
commit `31c1ad37456438565541f4919958214b6e762fb4`. The vendored header is used
only to turn TrueType outlines into an 8-bit coverage atlas. Metal uploads that
coverage to an R8 texture and performs Clock layout rendering and retained
RGB565/R8 output generation; Core Graphics and Core Image are not used.

- Upstream: <https://github.com/nothings/stb>
- Pinned source: <https://github.com/nothings/stb/blob/31c1ad37456438565541f4919958214b6e762fb4/stb_truetype.h>
- SHA-256: `ecd30b05e0dd4fea3a13c26810dd9e1992dc379049482c393d5a19e6b5090aab`
