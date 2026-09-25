<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
SPDX-License-Identifier: Apache-2.0
-->

# Application and pane ownership

LDTX enters through a single NSApplication and application delegate. NSWindowController owns each window, and PaneSplitViewController owns its sidebar, content, and inspector. Each pane hosts SwiftUI content in its own NSHostingController.

WorkspaceSession owns workspace state and resource lifetime. Pane visibility must not start or stop a workspace session. Model observations are registered by the session and stop when shutdown begins. The unified LDTXApp module owns the application, core state, and pane adapters; local editing and focus state remain inside pane views.

The workspace sidebar can be toggled with the toolbar button above the sidebar, before the content controls. It retains its expanded width and does not collapse automatically when the window is resized. Content absorbs window resizing first. Hosting controllers contribute natural minimum sizes; the native split constrains divider movement within the current window. Content does not extend beneath the side panes. The inspector retains a maximum width of 480 points, while the sidebar has no application-defined maximum.

Menus and toolbars route commands to their owning window. Closing a workspace confirms unsaved changes before awaiting resource shutdown. Application termination confirms all workspaces before stopping any of them; cancelling a later confirmation must not discard an earlier window's dirty state.

AppKit restoration uses versioned identifiers and stores file identity and pane geometry. Old SwiftUI scene state is not imported. Unsaved workspace content is not automatically persisted by restoration.

Run the `LDTXPaneSplitViewControllerSystemTests` scheme for AppKit split-view behavior. It uses the test runner's AppKit process and does not launch `LDTX.app`. `LDTXAppUIComponentTests` covers hostless SwiftUI `View` value and binding logic. The repository currently has no automated visible-UI tests that launch `LDTX.app`. The embedded XPC service process-boundary test remains isolated in `LDTXAppXpcTests`. Generate project changes with XcodeGen. Use a worktree-specific DerivedData directory and run signed builds and tests outside the sandbox as required by AGENTS.md.
