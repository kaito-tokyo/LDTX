<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# LDTX resource URLs

LDTX Automation identifies an open resource by one formal URL. The application
does not resolve titles, basenames, relative paths, or other shorthand forms.
Clients can call `ldtx.window.list` and perform shorthand resolution locally.

## Persistent resources

Saved Workspaces and recording previews use standardized absolute `file:` URLs.

```text
file:///Users/example/Live.ldtxworkspace
file:///Users/example/Recording.ldtxrecord
```

## Unsaved Workspaces

An unsaved Workspace has a process-local sequential URL:

```text
ldtx://workspace/unsaved/1
```

The canonical grammar is:

```text
ldtx://workspace/unsaved/<sequence>
```

`sequence` is a positive base-10 integer without leading zeroes. User info,
ports, query parameters, fragments, and a trailing slash are invalid. The URL
expires when the Workspace closes or is saved. Scene restoration may reserve
the same sequence while restoring that scene.

When Save As succeeds, the Router atomically replaces the `ldtx:` URL with the
Workspace's standardized `file:` URL. The previous URL immediately becomes
invalid.

## Window discovery

`ldtx.window.list` requires no parameters and returns every routable open
window. Each entry contains:

- `url`: the formal routing URL;
- `kind`: `workspace` or `recordingPreview`;
- `title`: a display name;
- `documentURL`: the persistent `file:` URL, when one exists.

All Workspace-scoped Automation requests require `workspaceURL` in their JSON-
RPC parameter object. The value must exactly identify one registered Workspace.
If no Workspace or more than one Workspace matches it, the request fails.

## CLI shorthand

The CLI accepts `--workspace <selector>`. It calls `ldtx.window.list`, resolves
the selector to exactly one formal Workspace URL, and sends only that URL to the
application. With one open Workspace, the option can be omitted. Ambiguous
selectors fail and print the formal candidate URLs.

The `ldtx:` scheme is currently an internal Automation identifier. It is not an
external deep-link scheme and is not handled by `application(_:open:)`.
