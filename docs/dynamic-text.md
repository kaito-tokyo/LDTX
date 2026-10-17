<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Dynamic Text persistence

Dynamic Text stores one flattened RTFD document in the Protobuf `bytes
rtfd_document` field. Its fonts, sizes, colors and paragraphs are the source of
formatting for both editing and Program rendering. Workspace versions remain 4
and 4.0. Earlier XML and token-text representations are unsupported; their field
numbers and names are reserved.

`LDTXRichText` uses the throwing NSAttributedString document APIs to read and
write RTFD. Corelibs preserves these bytes but validates only their presence;
macOS validates the contents before loading, saving or adopting a Workspace.
An empty text document still has valid RTFD bytes. Empty bytes are invalid.

## Variable attachments

Each variable is a regular `.ldtxvar` file attachment, with the exported type
`tokyo.kaito.ldtx.variable`. Its UTF-8 JSON has exactly these fields:

```json
{"version":1,"id":"123456","sel":"varname","body":"value"}
```

The three strings are opaque and may be empty. Unknown versions, missing or
additional fields, incorrect types, and non-variable attachments are rejected.
The application does not execute or validate the body as JavaScript.

Attachment filenames are generated for storage, not used as variable identity.
The FileWrapper contains the persistent JSON. The editor regenerates a chip cell
from it and the current display name; it does not replace the attachment with a
chip image. No custom character attribute is required to restore a variable.

Workspace interprets `id` as a Vision ID and `sel` as an output item such as
`text`, `label`, or `confidence`. Values are transient strings in a runtime-owned
dictionary. Missing references remain in the document and render as empty text.
Replacement values are literal text and inherit the attachment run's formatting.

## Editing and output

RTFD clipboard data preserves formatting and variable attachments. RTF and plain
text export replace variables with `{{id/sel}}`. Plain text paste never interprets
that syntax. Unsupported pasted attachments fail without replacing the selection.

Read, write and paste use the same codec. Display-only updates never rewrite the
stored bytes. Text and formatting edits publish an immutable RTFD snapshot into
Workspace Undo/Redo. Comparisons ignore attachment filenames and regenerated chip
presentation. RTFD bytes and NSFont object identity are not semantic equality.

Export checks that the text survives a native RTFD round trip. If a character
cannot be preserved, the edit remains visible as a draft with an error; the last
valid Workspace data is retained. Failed document reads never create empty text.

Program uses Core Text at the authored sizes, with wrapping and clipping instead
of automatic shrinking. A separate producer creates retained Metal textures on
content changes; frame rendering only composites them. The existing Dynamic Text
pixel budget applies before raster buffers are allocated.
