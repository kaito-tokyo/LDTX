<!-- SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo> -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

`menu-smoke.mp4` is a two-second, 32-by-32 black video with silent stereo audio.
It lets the menu smoke test open a real Record Player window without user media.
Generate it with:

```sh
ffmpeg -f lavfi -i color=c=black:s=32x32:r=1 -f lavfi -i anullsrc=r=48000:cl=stereo -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart menu-smoke.mp4
```
