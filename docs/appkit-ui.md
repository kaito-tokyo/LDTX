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
AppDelegate handles `applicationShouldOpenUntitledFile(_:)` by presenting the
standard Open panel only when the shared document controller has no documents,
then returning `false` to suppress automatic untitled document creation.
AppKit determines when to request this behavior during launch or reopening;
launch and restoration notifications do not independently present the panel.
Reopening uses AppKit's default window handling. No separate startup flags,
restoration observer, or delayed presentation are needed.
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
The Workspace sidebar owns one SwiftUI `.sheet(item:)` presentation for adding
input devices, video components, and OCR visions. The window injects its device
registry and app-local data. Form drafts do not change the document until Add
validates a live document, the current output state, name, and input references.
Missing documents disable Sidebar additions, and submission rechecks document
availability so an already-open sheet cannot add resources after release. Add
selects the new resource in the inspector without placing it in a Program or saving the
Workspace automatically. Physical-device assignments remain app-local. Content
has no duplicate input, component, or Vision creation controls; its Add Video
Layer menus place existing resources into the selected Program.

The Content pane implementation is organized by feature under
`Sources/Applets/Workspace/UI/Content`: Audio, VideoLayers, and Preview.
WorkspaceContent supplies the SwiftUI editor hosted below the AppKit preview.
AudioMixEditor and VideoLayersEditor contain their controls, while
WorkspaceContent supplies headings and layer actions using the same Workspace state.
Output and canvas settings, including their supporting types and helpers, live
under `Sources/Applets/Workspace/UI/Inspector`. Physical-device assignment is
owned by the video and audio input Inspectors, which share
WorkspacePhysicalDeviceField for selecting, clearing, and refreshing devices.

WorkspaceWindow uses PaneSplitViewController with hosted SwiftUI sidebar and
Inspector panes and an AppKit WorkspaceContentViewController in the center.
Record Player lives under Sources/Applets/RecordPlayer in the
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
uses NSDocument's standard document reopening and window restoration. Workspace
Inspector selection starts at nil and is neither encoded nor restored; the former
versioned selection key is ignored. AppKit owns frame and pane state.

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

The Workspace toolbar marks Stop and Start/Pause as navigational items, in that
order, so AppKit places them before the standard document title. The window uses
the unified toolbar style; AppKit manages the title's placement and synchronizes
it with the document name. Content does not repeat the title in its editor.
Toolbar controls project the V4 recording session state. Pause drains
and finalizes the current output and leaves the session paused; the next Start
creates a new output session. Stop from paused returns to idle. Transition states
keep definition editing and output toolbar actions disabled, and finalization
failures remain visible. Pause state is not persisted in the Workspace package.

The Workspace Content pane uses an AppKit horizontal split above its SwiftUI
scrollable editor. `WorkspaceWindowController` owns the
`ProgramPairPreviewRenderer`, which reads the same Program runtimes used for
output. `ProgramCanvasPairedPreview` receives its Metal device and delegate,
centers a fixed 16:9 plus 9:16 pair, and shows black when frames are absent.
Preview clicks and accessibility actions update the window's transient
`isPortraitAudio` selection without changing document contents.

The divider starts at 280 points with a 100-point minimum for each pane. User
drags save `contentPreviewHeightRatio` in Workspace-local state; reopening
restores that ratio within the available height. Window resizing does not
replace the saved ratio. Shutdown pauses the MTKView, detaches its delegate,
and stops the renderer before shutting down the runtimes.

### Dynamic reference selection

Workspace Sidebar selection starts at `nil` and is not restored by AppKit. Explicit user selection and resource-addition selection remain window-local.

Physical assignments, VFX/OCR inputs, monitor output devices, and stream keys show their current value separately from a Change sheet. Each sheet owns an initially unselected draft and applies it only after checking availability and edit permissions. Cancel leaves the model untouched. Unresolved or unavailable references remain visible without rewriting their saved IDs. Assignment removal and use of the default monitor device are explicit actions. Fixed enumerations retain their existing controls.

### Video layer editing belongs to Content

The Workspace Content scroll area begins with Landscape and Portrait video layer lists below the fixed preview. Layer addition, ordering, removal, mute, and transform controls live there. Sidebar selects Workspace settings and resources; it has no Video Layers entry or corresponding Inspector. Layer editing does not change Sidebar selection.

The Video Layers group uses a standard SwiftUI DisclosureGroup to collapse both
canvas lists together. It starts expanded and keeps its disclosure state local
to the Content view, without saving it in the Workspace.

### Program selection in the Inspector

The first entry in Sidebar's WORKSPACE section is Programs. Selecting it opens
an Inspector containing a standard vertical SwiftUI radio-group Picker.
Content contains only the fixed previews and scrollable editor; Program selection
has no reserved row, horizontal scrolling, or custom layout sizing.

The Program candidates are static entries in the Workspace definition. The
Picker uses matching optional `UInt64` selection and tag values and reads the
resolved Program directly from model state. Its setter uses the existing
dispatcher; failed changes retain the model selection and display the error in
the Inspector. No independent selection state is kept. With an empty Program
array, the Inspector displays "No Program" instead of constructing a Picker.
The empty Content preview remains visible. Resolving a stale saved ID does not
rewrite it. Sidebar initially remains unselected.

The controller validates both canvas projections before updating the
Workspace-local selection. Selection leaves Sidebar and Inspector state alone.
Program changes are allowed during output, but not during start, pause, or stop.
Both existing runtimes and output audio mixes receive the selected Program's
configuration and preferences. Recording packages and publishing sessions stay
open across the change; output failures follow the normal finalization path.
