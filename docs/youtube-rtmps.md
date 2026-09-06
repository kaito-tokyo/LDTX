<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: CC0-1.0
-->

# YouTube RTMPS output

YouTube Dual stream is one live event fed by two independent encoder outputs. The
Landscape publisher sends 1920x1080 media to the Default stream key. The
Portrait publisher sends 1080x1920 media to the Vertical stream key selected in
YouTube Studio. LDTX retains Landscape and Portrait for its Canvases and uses
Default and Vertical for the corresponding YouTube destinations. YouTube owns
the association between those keys; LDTX does not create, infer, or persist that
association.

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

Manage Stream Keys manages named configurations. Each configuration contains an
RTMPS Stream URL, an optional Backup Server URL, and a shared Stream Key. Users
can enter these fields or import a configuration from YouTube. Save validates
both URLs and saves the complete collection to the macOS Keychain; Cancel
leaves the saved collection unchanged. Keys are masked in the editor.

The Output pane persists only the ingest mode (`DASH` or `YouTube RTMPS`) in the
Workspace. For YouTube RTMPS, Default and Vertical select different saved
configurations. These assignments remain local to the open Workspace and are
retained when output stops. The selected primary URL and key are used directly
at startup, without re-fetching or replacing the configuration from YouTube.
Manually configured output does not require OAuth. Importing from YouTube does.

Configuration credentials must not be written to Workspace files, preferences,
logs, diagnostics, error descriptions, or state restoration data. The Keychain
is the only persistent credential store. YouTube owns the association between
stream keys and events; LDTX does not change that association. API health checks
are available for imported configurations until their connection fields are
edited; local configuration IDs are never sent as YouTube LiveStream IDs.

The Backup Server URL is stored and validated together with the primary URL and
key. Publishing currently uses the primary URL only; automatic failover or
simultaneous publishing to the backup server is not implemented.

The existing DASH Landscape output remains available. RTMPS owns one
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
