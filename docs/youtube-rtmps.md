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

The Stream Keys tab in Settings manages named configurations. Each
configuration contains an RTMPS Stream URL, an optional Backup Server URL, and a
shared Stream Key. Users enter these fields in a sheet for one configuration.
Save validates both URLs, requires unique names and keys, and saves the complete
collection to the macOS Keychain; Cancel leaves the saved collection unchanged.
Keys are masked in the editor.

Import from YouTube lists the LiveStreams of the account authorized in the
Account tab, using the YouTube Live API's `liveStreams.list` with `mine=true`.
The list keeps only titles, stream status and whether a complete RTMPS
destination exists; the stream URL and key are fetched for the chosen LiveStream
alone. Only `rtmp` LiveStreams with an RTMPS ingestion address can be imported.
The LiveStream title becomes the name, made unique among saved configurations,
and the LiveStream ID is kept as the configuration's source. Importing a
LiveStream again refreshes that configuration's connection fields in place,
keeping its ID, name and Workspace assignments. When YouTube's RTMPS backup
address carries a query, such as `?backup=1`, the backup URL validation rejects
it and the imported configuration has no backup server URL.

The Output pane persists only the ingest mode (`DASH` or `YouTube RTMPS`) in the
Workspace. For YouTube RTMPS, Default and Vertical select different saved
configurations. These assignments remain local to the open Workspace and are
retained when output stops. The selected primary URL and key are used directly
at startup, without re-fetching or replacing the configuration from YouTube.
Manually configured output does not require OAuth. Importing from YouTube does.

Configuration credentials must not be written to Workspace files, preferences,
Unified Logger messages, error descriptions, or state restoration data. The
Keychain is the only persistent credential store. YouTube owns the association
between stream keys and events; LDTX does not change that association. A
configuration's optional YouTube LiveStream ID is cleared when its connection
fields are edited; local configuration IDs are never sent as YouTube LiveStream
IDs.

The collection is one generic-password item in the data-protection keychain, in
the application's default access group, readable only after the first unlock on
the same Mac. Every save applies that accessibility to new and existing items.
Versions before this policy stored the collection in the legacy file-based
keychain, where the accessibility attribute has no effect. That item is not
migrated: when the data-protection item is missing, the legacy item is deleted,
so users enter their stream keys again once. The data-protection keychain
requires the `keychain-access-groups` entitlement, so builds signed without
entitlements, such as ad-hoc CI builds, report a Keychain failure instead of
saving stream keys. The YouTube authorization stores follow the same policy; see
`docs/appkit-ui.md`.

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
