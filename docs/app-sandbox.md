<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# App Sandbox

`LDTXApp` runs in the App Sandbox. Its policy is declared in
[`Sources/Apps/LDTXApp/LDTX.entitlements`](../Sources/Apps/LDTXApp/LDTX.entitlements).
The Quick Look preview and thumbnail extensions have their own sandboxed
entitlements.

## Decision

LDTX is distributed with Developer ID, so the sandbox is not a distribution
requirement. LDTX enables it to limit what a compromised process can reach:
Workspace and recording packages, camera and microphone input, and network
output are the app's main attack surface. Sandboxing was postponed while the
app embedded a YouTube DASH output XPC service. That service has been removed,
so the app now runs as one sandboxed process.

The trade-off is that the user must grant access to every folder outside the
container, and those grants must be persisted explicitly. Hardened Runtime
remains enabled independently of the sandbox.

## Entitlements

| Entitlement | Reason |
| --- | --- |
| `com.apple.security.app-sandbox` | Enables the sandbox. |
| `com.apple.security.network.client` | RTMPS publishing, the YouTube Live API, OAuth token requests, and DASH upload. |
| `com.apple.security.network.server` | The OAuth loopback redirect listener in `AppAuthAuthorizationPresenter`. |
| `com.apple.security.device.usb` | Stream Deck access through `IOHIDManager`. |
| `com.apple.security.device.camera`, `com.apple.security.device.audio-input` | Capture input devices. |
| `com.apple.security.files.user-selected.read-write` | Opening and saving Workspace and recording documents, importing models and OAuth clients, and choosing output folders. |
| `com.apple.security.files.bookmarks.app-scope` | Restoring chosen output folders after relaunch. |
| `com.apple.security.assets.movies.read-write` | The default recording folder, `~/Movies`. |
| `com.apple.security.assets.pictures.read-write` | The default screenshots folder, `~/Pictures`. |

Keychain access groups, iCloud Documents, and the continued-processing
inference entitlement were already compatible with the sandbox. Stream keys use
the data-protection Keychain. LDTX uses no screen capture APIs.

## Output folders

A folder chosen in an open panel is accessible only until the app quits. The
default recording folder, the screenshots folder, and each Workspace's
recording folder are therefore stored as a path and an app-scoped
security-scoped bookmark (`SecurityScopedFolder`). The path is displayed and is
the fallback when no bookmark exists or it cannot be resolved. A resolved
folder stays accessible for the rest of the process lifetime, because
recordings and screenshots write to it at arbitrary times; each bookmark starts
access at most once per process. Changing a Workspace's recording folder path
discards its bookmark.

The default folders come from `URL.moviesDirectory` and `URL.picturesDirectory`.
Inside the sandbox these name links in the container, so they are resolved to
the user's real folders before being displayed or revealed in Finder.

## Other executables

- `LDTXHelper`, the MCP server in `Contents/Library/Helpers`, is started by MCP
  clients rather than by the app, so it does not inherit the app's sandbox. It
  is currently a stub with no IPC to the app.
- The Vision Programmer app has its own target and is not covered by this policy.

## Migration

- Folders chosen before the sandbox have a path but no bookmark. The sandboxed
  app cannot write to them, so output reports the folder as not writable until
  the user chooses it again. The default `~/Movies` and `~/Pictures` folders keep
  working.
- Application Support, caches, and temporary files move into the container. The
  development-only `.YouTubeAuth` file is not migrated; authorize again.
- Whether macOS migrates the existing UserDefaults domain into the container on
  the first sandboxed launch must be confirmed on a signed build. If it does
  not, Settings, Stream Deck assignments, and Workspace-local state reset once.

## Validation

Source changes cannot prove the policy. On a signed build, inspect the effective
entitlements with `codesign -d --entitlements - LDTX.app` and confirm:

- opening, saving, and reopening Workspace and recording packages, locally and
  in iCloud Drive;
- camera and microphone capture;
- local recording and screenshots to the default folders and to chosen folders,
  including after relaunch;
- RTMPS streaming, DASH upload, and YouTube OAuth authorization;
- Stream Deck input;
- Vision model import and OAuth client import; and
- notification attachments and Show in Finder for saved files.
