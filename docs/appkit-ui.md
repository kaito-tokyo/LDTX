<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
SPDX-License-Identifier: Apache-2.0
-->

# Application and pane ownership

LDTX enters through a single NSApplication and application delegate. Workspace
and recording files are NSDocument instances managed by the shared
NSDocumentController.shared. AppKit creates the standard controller and uses
the first Editor type in Info.plist (Workspace) as the default New document type.
AppKit initializes each document and selects
the registered document class for each file type. File menu New and Open use the
shared document controller's standard actions. AppDelegate suppresses automatic
untitled documents and presents the standard Open panel after launch and
restoration when no documents are open and no file-open request was received.
Reopening the application without visible windows presents the Open panel again.
Cancelling the panel leaves the application running; File > New creates an
untitled Workspace without first requesting a save location.
Workspace duplication is unsupported for its resource model. The File menu omits
Duplicate, and both the document action and direct duplication reject the
operation. Save As remains available when output is idle.
WorkspaceDocument projects the registered documents' output state into
NSApplication.shared.dockTile.badgeLabel. The Dock is a write-only display sink;
no independent recording identifiers or activity store are maintained. The badge
remains active until all output stops.
WorkspaceDocument owns the V4 model, package lock, and persistence coordinator.
It uses WorkspaceAppletData.shared from initialization, and acquires its package
lock during reading. Recovery initialization distinguishes the formal document
URL from autosaved contents; failed reads and document teardown release locks.
It creates and registers WorkspaceWindowController with addWindowController;
AppKit owns document and window-controller lifetime. The controller constructs
window-scoped runtime resources and injects operations into the pane views.
Each document creates one DocumentReference from LDTXAppletSupport when constructing
its window controller. All SwiftUI pane roots receive that same box through the
documentReference environment value. The box weakly references NSDocument; views
and hosting controllers do not extend the document's lifetime. UI actions query
NSDocument.fileURL when they run, including Binding getters and setters. Workspace
local settings use uiState.localStateURL only as the transient key while fileURL
is nil. Missing environments and released documents disable document-dependent
settings operations. Existing observable models drive presentation updates;
the weak reference is not a change-observation mechanism. Read and write hooks
continue to use AppKit's supplied URLs rather than the environment.
WorkspaceWindow uses a standard NSSplitViewController with an NSHostingController
for each pane. Record Player lives under Sources/Applets/RecordPlayer in the
LDTXRecordPlayerApplet module. Its small implementation uses a flat directory.
RecordPlayerDocument uses NSDocument.fileURL as the recording location and owns
in-memory marker edits. It registers a
RecordPlayerWindowController that composes the panes and owns playback lifetime.
Marker edits notify NSDocument and remain in memory until Save. A coordinated
safe save replaces only the Markers directory, retaining unknown files and leaving
media and metadata untouched. Active recordings and external marker changes reject
saving. Recording documents support explicit Save and Revert, without autosave,
versions, or UI access to Save As, Duplicate, Move, or Rename. Standard UI
validation disables these actions; their inherited implementations are not overridden.
The save hook rejects operations other than saving markers to the current package.
Closing uses AppKit’s save/discard/
cancel confirmation before playback stops. PaneWindow retains existing pane state
keys; document and window restoration use AppKit’s standard document path.

New creates an untitled Workspace document. Workspace Save, Save As, Duplicate,
Revert, autosave, and
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
`LDTXRecordPlayerDocumentSystemTests` for recording document ownership, marker saving, and close confirmation,
`LDTXWorkspaceAppletControllerSystemTests` for Workspace window behavior and `LDTXPaneSplitViewControllerSystemTests` for Record Player's shared split behavior. These run in the test runner's AppKit process and do not launch `LDTX.app`. `LDTXAppUIComponentTests` covers hostless SwiftUI `View` value and binding logic. The repository currently has no automated visible-UI tests that launch `LDTX.app`. The embedded XPC service process-boundary test remains isolated in `LDTXAppXpcTests`. Generate project changes with XcodeGen. Use a worktree-specific DerivedData directory and run signed builds and tests outside the sandbox as required by AGENTS.md.

## Source folders

XcodeGen source roots under `Sources` use `syncedFolder`. Intermediate groups
preserve the Sources and Applets hierarchy. Sources/LDTX* folders and each applet
folder are synchronized roots; Workspace subdirectories are discovered inside
one Workspace root rather than registered as separate navigator groups.

Workspace retains its existing module boundaries because lower-level frameworks
also consume its model. Each Workspace target includes only its own Controller,
Interface, Model, Service, Store, or UI subdirectory. XcodeGen generates the
per-target membership exceptions, so a source compiles in one Xcode target.
Adding or removing Workspace files requires regenerating the project to update
these exceptions. SwiftPM-only entrypoints remain managed by Package.swift.

XcodeGen 2.46 does not generate synchronized-folder public-header visibility
exceptions. The AudioEngine and FontRasterizer public headers therefore retain
explicit header entries in virtual Public Headers groups, excluded from automatic
folder membership. Internal headers remain filesystem-visible compile dependencies.
Fonts and licenses live under Resources/LDTX/Fonts/NotoSans, outside source roots,
with their existing bundle copy destinations preserved.

Record Player panes and the playback model do not cache the document location.
The model uses the shared weak DocumentReference to read fileURL at the start of
an asset load. Existing playback resources remain alive across external moves;
subsequent canvas loads use the current document URL. AppKit manages document
access, without a separate security-scope lifetime or application move observer.
Marker identity is a package-relative filename, never an absolute URL. Save
synchronizes the in-memory snapshot at the URL supplied by AppKit, comparing the
path-independent baseline and preserving unknown files. Access failures preserve
pending marker edits and are reported through the existing error paths.

RecordPlayerDocument is observable and is the sole owner of marker contents.
Player panes observe its markers through the weak document environment; playback
models contain no marker copies or editing callbacks. Marker edits enter through
the document methods, which maintain AppKit change counts separately from
Observation notifications. Save baselines and other lifecycle bookkeeping are
excluded from Observation. Missing documents disable marker actions, and Revert
clears selections whose marker filenames no longer exist.
