<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: CC0-1.0
-->

# YouTube RTMPS output

YouTube Dual stream is one live event fed by two independent encoder outputs. The
Landscape publisher sends 1920x1080 media to the event's normal stream key. The
Portrait publisher sends 1080x1920 media to the second stream key selected in
YouTube Studio. YouTube owns the association between those keys; LDTX does not
create, infer, or persist that association.

`LDTXYouTubeRTMPS` implements only the client-side subset needed to publish
H.264 and AAC to YouTube:

- RTMP 1.0 over authenticated TLS with SNI, using an `rtmps` URL on port 443.
- The simple handshake and the `connect`, `createStream`, and `publish` commands.
- RTMP chunk framing, acknowledgements, window-size control, and ping responses.
- FLV AVC and AAC sequence headers and media packets.

It does not support clear-text RTMP, receiving, playback, server operation,
proxying, non-AVC video, non-AAC audio, or compatibility with other services.
The module consumes a typed destination but does not depend on OAuth or the
YouTube Live API.

The ingestion URL and stream name are secrets held only for the active output
session. They must not be written to Workspace files or included in logs,
diagnostics, error descriptions, or state restoration data.

The Output pane persists only the ingest mode (`DASH` or `Dual RTMPS`). When
Dual RTMPS is selected, the user chooses different Landscape and Portrait
LiveStreams for the current session. Their IDs and resolved destinations remain
session-local; LDTX neither persists them nor changes their YouTube Studio event
association.

The existing DASH Landscape output remains available. RTMPS Dual owns one
publisher per Canvas; queues, protocol state, and reconnection state are not
shared. Start succeeds only after both publishers enter publishing state. A
terminal failure in either publisher stops both publishers and fails the Output
Session. A transient failure uses a finite exponential-backoff reconnect and
resumes at a keyframe after resending both codec sequence headers.

Normative references:

- [YouTube Dual stream](https://support.google.com/youtube/answer/2474026)
- [YouTube RTMPS ingestion](https://developers.google.com/youtube/v3/live/guides/rtmps-ingestion)
- [YouTube LiveStream resource](https://developers.google.com/youtube/v3/live/docs/liveStreams)
- Adobe RTMP Specification 1.0
- Adobe Flash Video File Format Specification 10.1
