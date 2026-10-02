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
the registered document class for each file type. File menu Open uses the shared
document controller's standard action. New uses AppDelegate to create a hidden
document through the shared controller and requests standard document saving.
AppDelegate suppresses automatic
untitled documents and presents the standard Open panel after launch and
restoration when no documents are open and no file-open request was received.
Reopening the application without visible windows presents the Open panel again.
Cancelling the panel leaves the application running; File > New creates a
Workspace and immediately requests its first save location. Cancelling this save
closes only the new document. A write failure is presented and also closes the
new document, leaving any incomplete package on disk. Window controllers are
constructed and shown only after initial saving succeeds. Workspace UI
validation disables Save As, Save To, and Duplicate. Their inherited actions are
not overridden, while the save path rejects copying an already-saved document.
WorkspaceDocument projects the registered documents' output state into
NSApplication.shared.dockTile.badgeLabel. The Dock is a write-only display sink;
no independent recording identifiers or activity store are maintained. The badge
remains active until all output stops.
WorkspaceDocument owns the V4 model and persistence coordinator. It uses
WorkspaceAppletData.shared from initialization. No lifetime package lock or sidecar
lock file is used. Restoration reads the formal package only; a missing, nil, or
unreadable formal URL is an error even when legacy recovery contents exist.
Legacy recovery data, versions, and lock files are not deleted or adopted.
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
Marker additions and replacements notify NSDocument and stay in memory until Save.
Markers are auxiliary information without strict conflict detection. A coordinated
save atomically writes individual marker files, then reads the disk contents under
the same coordination and updates the document's observable marker list. Disk-only
markers and unknown files remain intact; media and required metadata are untouched.
There is no baseline comparison, whole-directory replacement, or rollback. A failed
write or reread preserves the document's edits and change state for retry, even if
some files were already written. Timestamp identity uses millisecond precision and
reuses the first existing filename in filename order. Other same-time files remain
untouched. Existing empty notes can be saved; new empty notes are rejected.
Deletion requires a separate confirmation and immediately removes the file before
updating memory. Missing files count as deleted. Deleting does not add a save change
count or clear pending edits, and choosing Don't Save on close cannot restore deleted
markers. Marker Undo/Redo is not provided. Active recordings reject writes.
Recording documents support explicit Save without autosave or versions. Standard
UI validation disables Revert, Save As, Duplicate, Move, and Rename; their inherited
implementations are not overridden.
The save hook rejects operations other than saving markers to the current package.
Closing uses AppKit’s save/discard/
cancel confirmation before playback stops. PaneWindow retains existing pane state
keys; document and window restoration use AppKit’s standard document path.

Workspace Save and Revert use AppKit's lifecycle and change-count tracking.
Autosaving and version preservation are disabled. Definition and preferences
edits remain in memory until an explicit Save, including saving selected during
standard close and termination confirmation. WorkspaceDocument captures an
immutable V4 snapshot, releases interaction before filesystem work, and writes
on AppKit's background saving thread. A captured AppKit change-count token keeps
edits made during writing unsaved when the non-autosaving save completes.
Coordinated ordinary saves atomically
replace only definition.pb and preferences.pb, leaving Info.plist, resources, and
unknown files untouched. Initial saving creates Info.plist and the two model
files. The two writes are individually atomic, not a transaction: a failure can
leave mixed revisions on disk and retains unsaved edits. No journal, rollback,
backup, or recovery-package copying is added. The save hook rejects autosave,
export, and subsequent Save As operations.
WorkspaceV4PersistenceCoordinator projects the document's model for runtimes;
it has no independent save API. WorkspaceWindowRuntime and UI dispatchers do not
write definition or preferences. CLI package operations use file coordination
instead of the former lifetime lock. Ordinary document opening, duplicate URL
reuse, external-change detection, and file coordination remain AppKit-managed.

Recording or streaming starts from the current in-memory model without saving
pending edits. A formal document URL is required. Revert, Move, and Rename remain
disabled during output. Closing uses NSDocument's standard save decision and
waits for runtime shutdown before granting permission.
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
writes the in-memory snapshot at the URL supplied by AppKit, then synchronizes
from disk without comparing a baseline and without deleting unknown files. Access failures preserve
pending marker edits and are reported through the existing error paths.

RecordPlayerDocument is observable and is the sole owner of marker contents.
Player panes observe its markers through the weak document environment; playback
models contain no marker copies or editing callbacks. Marker edits enter through
the document methods, which maintain AppKit change counts separately from
Observation notifications. Lifecycle bookkeeping is excluded from Observation.
Missing documents disable marker actions. Save synchronization and immediate
deletion clear selections whose marker filenames no longer exist.

Physical input assignments are app-wide and keyed only by InputDevice internalID.
WorkspaceAppletData owns the observable dictionary and stores it as a binary plist
under tokyo.kaito.ldtx.input-device-assignments.v1. Same IDs share assignments across
workspaces; nil removes an assignment. Closing a document or deleting an input does
not remove its stored assignment. Legacy URL-keyed device assignments are ignored
and require reselection; the remaining WorkspaceLocalState fields are retained.
UI bindings access the assignment API without a document URL. Runtime projections
and recording sessions receive an explicit assignment provider or snapshot. Each
window observes shared changes and updates program runtimes, physical captures,
and audio monitoring, cancelling its observer during shutdown. Program selection,
monitor selection, mix synchronization and YouTube selection remain path-keyed;
relocation cleanup for those fields is a separate change.
