<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
SPDX-License-Identifier: Apache-2.0
-->

# Stream Deck MK.2

LDTX uses a single connected MK.2 (USB vendor 0x0fd9, product 0x0080).
The first three keys in the top row are Stop, Start/Pause, and Take Screenshot.
Other keys are blank. Keys use the toolbar's SF Symbols: `stop.fill`, `play.fill`,
`pause.fill`, and `camera`. Stop is red, Start is green, Pause is orange, and
Screenshot is blue. Unavailable controls use a white symbol with a diagonal slash.
All diagonal slashes are drawn consistently using Core Graphics.
Start changes to Pause
while recording. No toolbar setup, profiles, Program switching, or Shortcuts are involved.
Backlight brightness is set to 100% whenever LDTX connects to the device.

The target is the most recently active Workspace window, published through
SwiftUI's `focusedSceneValue` and read by the application using `@FocusedValue`.
AppDelegate retains the selection when focus leaves that window, including when
another Applet or application becomes active. Activating another Workspace
transfers control to it. The application keeps the HID connection independently
of window focus. A sheet on the target or an application modal dialog temporarily
disables the keys. Closing the target disables controls until a Workspace becomes
active; there is no fallback to a different open Workspace. A press captures its
target; changes to the displayed state or connection invalidate pending presses.
Output uses the same toolbar admission and runtime actions. Screenshots use the
same coordinator capture path and report errors in the Workspace error UI.
Hardware screenshot success does not open a result popover.

One application-owned worker discovers devices once per second. Zero or multiple
matching devices disable the connection. Device open uses IOKit's exclusive seize
option; a busy or denied device is left alone. No permission requests, security
changes, or other-process termination are performed. The connection retries after
unplug/replug or a busy owner releases it. When an initial key-state snapshot is
available through GET_REPORT, held keys must be released before use. Otherwise,
incoming input reports are handled immediately without discarding the first press.
Malformed reports are ignored.
Stop and Take Screenshot trigger on key down. Start/Pause triggers only on key up
after a key down observed on the current connection. Repeated reports do not
repeat commands, and there is no timed debounce. During an admitted hardware action other
hardware commands are disabled until that action completes.

A dedicated thread owns all HID calls, JPEG rasterization and image transfers.
A bounded latest-frame mailbox coalesces changes; unchanged images are cached and
not resent. UI state is sampled every 100 ms, and rechecked on MainActor at press
execution. Runtime commands continue to use the existing Workspace command queue.
On a clean disconnect/shutdown the device logo is restored on the worker thread.
The logo is also restored when there is no eligible target or its Workspace
begins closing, while the application keeps the device connection. Selecting
another eligible Workspace redraws the complete key layout.
Shutdown waits for the worker to restore the logo, close the device, and tear
down discovery before returning. Removal notifications are registered with the
HID manager so unplugged devices are removed from its enumeration set.
