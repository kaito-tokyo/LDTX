<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
SPDX-License-Identifier: Apache-2.0
-->

# Application and pane ownership

LDTX enters through a single NSApplication and application delegate. NSWindowController owns each window. WorkspaceAppletController creates the Workspace views and dependencies, then passes three hosting controllers to WorkspaceWindow. WorkspaceWindow uses a standard NSSplitViewController internally and owns Workspace pane layout, visibility, and restoration. Record Player continues to use the shared PaneWindow and PaneSplitViewController. Each pane hosts SwiftUI content in its own NSHostingController.

`WorkspaceWindowRuntime` owns the Workspace bundle store, persistence coordinator,
runtime projections, capture coordination, and window-scoped resource lifetime.
`WorkspaceAppletController` creates that runtime and injects its operations into
the pane views. Pane visibility must not start or stop Workspace resources.
All `.ldtxworkspace` package filesystem access is implemented by
`LDTXWorkspaceBundleFormat`; the Runtime chooses when to load/save and retains
the lock token, while Store and views operate on in-memory package values.
The runtime is created independently of `WorkspaceUIState`; the UI state is
initialized first and then populated from the opened bundle. The unified
LDTXApp module owns the application and pane adapters; local focus state remains
inside pane views.

Workspace starts with a 240-point sidebar, 480-point content pane, and 340-point inspector. The sidebar and inspector can be toggled from their toolbar buttons; each retains its expanded width and does not collapse automatically when the window is resized. Content absorbs window resizing first. Content does not extend beneath the side panes. The inspector has a maximum width of 480 points, while the sidebar has no application-defined maximum.

Menus and toolbars route commands to their owning window. Closing a workspace confirms unsaved changes before awaiting resource shutdown. Application termination confirms all workspaces before stopping any of them; cancelling a later confirmation must not discard an earlier window's dirty state.

AppKit restoration uses versioned identifiers and stores the Workspace URL, window frame, pane widths, and collapsed states using the existing restoration keys. Old SwiftUI scene state is not imported. Unsaved workspace content is not automatically persisted by restoration.

Run `LDTXWorkspaceAppletControllerSystemTests` for Workspace window behavior and `LDTXPaneSplitViewControllerSystemTests` for Record Player's shared split behavior. Both run in the test runner's AppKit process and do not launch `LDTX.app`. `LDTXAppUIComponentTests` covers hostless SwiftUI `View` value and binding logic. The repository currently has no automated visible-UI tests that launch `LDTX.app`. The embedded XPC service process-boundary test remains isolated in `LDTXAppXpcTests`. Generate project changes with XcodeGen. Use a worktree-specific DerivedData directory and run signed builds and tests outside the sandbox as required by AGENTS.md.
