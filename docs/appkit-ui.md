<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
SPDX-License-Identifier: Apache-2.0
-->

# Application and pane ownership

LDTX, LDTXTiny, and LDTX Player enter through NSApplication. Their application delegates own file routing and window registries. NSWindowController owns each window, and PaneSplitViewController owns its sidebar, content, and inspector. Each pane hosts SwiftUI content in its own NSHostingController.

WorkspaceSession owns workspace state and resource lifetime. Pane visibility must not start or stop a workspace session. Model observations are registered by the session and stop when shutdown begins. Pane adapters translate session state into bindings and callbacks without introducing a dependency from LDTXAppUI to LDTXAppCore. Local editing and focus state remain inside pane views.

The workspace sidebar can be toggled with the toolbar button above the sidebar, before the content controls. It retains its expanded width and does not collapse automatically when the window is resized. Content absorbs window resizing first. Hosting controllers contribute natural minimum sizes; the native split constrains divider movement within the current window. Content does not extend beneath the side panes. The inspector retains a maximum width of 480 points, while the sidebar has no application-defined maximum.

Menus and toolbars route commands to their owning window. Closing a workspace confirms unsaved changes before awaiting resource shutdown. Application termination confirms all workspaces before stopping any of them; cancelling a later confirmation must not discard an earlier window's dirty state.

AppKit restoration uses versioned identifiers and stores file identity and pane geometry. Old SwiftUI scene state is not imported. Unsaved workspace content is not automatically persisted by restoration. Standalone Player windows do not reopen automatically.

Run the LDTXAppLifecycleTests Xcode scheme for application, lifecycle, and native divider regression tests. Generate project changes with XcodeGen. Use a worktree-specific DerivedData directory and run signed builds and tests outside the sandbox as required by AGENTS.md.

## Test-only close behavior

Debug builds accept `-tokyo.kaito.ldtx.LDTX.discardsUnsavedChangesOnClose YES`. For example:

```sh
open -n -a /path/to/Debug/LDTX.app --args -tokyo.kaito.ldtx.LDTX.discardsUnsavedChangesOnClose YES
```

This UserDefaults option discards unsaved workspace changes without asking when closing a window or quitting. It does not save automatically and does not bypass asynchronous resource shutdown. It is independent of `isUITesting`, when passed as a launch argument is not persisted in preferences, and is ignored by Release builds.
