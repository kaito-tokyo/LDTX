<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
SPDX-License-Identifier: Apache-2.0
-->

# Application and pane ownership

LDTX enters through a single NSApplication and application delegate. Workspace
files are NSDocument instances managed by the shared WorkspaceDocumentController.
The document controller belongs to the Workspace applet controller module. LDTXApp
creates it and injects recording routing, recording activity reporting, and
Launcher presentation callbacks.
WorkspaceDocument owns the V4 model, package lock, and persistence coordinator.
It creates and registers WorkspaceAppletController with addWindowController;
AppKit owns document and window-controller lifetime. The controller constructs
window-scoped runtime resources and injects operations into the pane views.
WorkspaceWindow uses a standard NSSplitViewController with an NSHostingController
for each pane. Record Player continues to use PaneWindow and PaneSplitViewController.

New creates an untitled document. Save, Save As, Duplicate, Revert, autosave, and
unsaved-document recovery use AppKit's document lifecycle. Model mutations notify
NSDocument synchronously through updateChangeCount. Package snapshots retain
resources and metadata; LDTXWorkspaceBundleFormat performs package serialization,
and NSDocument handles safe saving and file coordination. Recovery and temporary
save URLs do not become the runtime's formal package URL. App-local state remains
transient until the first successful save and follows subsequent Save As operations.

Recording or streaming first saves the document through the standard save panel
when needed. Save As and Revert are disabled during output. Duplicate creates an
independent document without running output. Closing uses NSDocument's standard
save decision and waits for runtime shutdown before returning permission to close.
Application termination uses AppKit's per-document review. Cancelling does not
reopen documents that have already closed. Pane visibility does not own resource
lifetime.

Workspace starts with a 240-point sidebar, 480-point content pane, and 340-point inspector. The sidebar and inspector can be toggled from their toolbar buttons; each retains its expanded width and does not collapse automatically when the window is resized. Content absorbs window resizing first. Content does not extend beneath the side panes. The inspector has a maximum width of 480 points, while the sidebar has no application-defined maximum.

The Program preview's single `MTKView` belongs to the Content pane. A
`ProgramPairPreviewRenderer` supplied as its delegate reads the latest
`ProgramFrame` from the Landscape and Portrait runtimes and draws the 16:9 and
9:16 images at equal height into the drawable. The four-pixel gap is transparent
so the pane's background shows through; the drawable uses linear
`BGRA8Unorm`.

Menus and toolbars route commands to their owning window. Workspace restoration
uses NSDocument's standard document reopening and window restoration. Inspector
selection keeps its existing versioned state key; AppKit owns frame and pane state.

Run `LDTXWorkspaceDocumentSystemTests` for document lifecycle and saving,
`LDTXWorkspaceAppletControllerSystemTests` for Workspace window behavior and `LDTXPaneSplitViewControllerSystemTests` for Record Player's shared split behavior. These run in the test runner's AppKit process and do not launch `LDTX.app`. `LDTXAppUIComponentTests` covers hostless SwiftUI `View` value and binding logic. The repository currently has no automated visible-UI tests that launch `LDTX.app`. The embedded XPC service process-boundary test remains isolated in `LDTXAppXpcTests`. Generate project changes with XcodeGen. Use a worktree-specific DerivedData directory and run signed builds and tests outside the sandbox as required by AGENTS.md.
