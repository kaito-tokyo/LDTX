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
local settings use storeService.localStateURL only as the transient key while fileURL
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
WorkspaceContentPane is an NSViewController containing the configured AppKit preview
and the editors in a vertical NSSplitView. It does not subclass NSSplitViewController.
MasterVolumeEditor and AudioMixEditor remain visible above the Landscape Video
Layers and Portrait Video Layers tabs, which use VideoLayersEditor controllers.
Each editor owns its Observation task and reads the shared WorkspaceStoreService.
The editor stack is the vertical NSScrollView's document view directly. Its
flipped coordinates keep the controls at the top, and its width tracks the
viewport without an intermediate container. Reducing the lower pane height scrolls the controls rather
than requiring the pane to fit all editors at once.
Output and canvas settings, including their supporting types and helpers, live
under `Sources/Applets/Workspace/UI/Inspector`. Physical-device assignment is
owned by the video and audio input Inspectors, which share
WorkspacePhysicalDeviceField for selecting, clearing, and refreshing devices.

WorkspaceWindow configures its NSSplitViewController directly with hosted SwiftUI sidebar and
Inspector panes and an AppKit WorkspaceContentPane in the center.
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

WorkspaceWindowController constructs and retains the Program preview's single
`MTKView`, then passes the configured preview to the Content view controller. A
`ProgramPairPreviewRenderer` supplied as its delegate reads the latest
`ProgramFrame` from the Landscape and Portrait runtimes and draws the 16:9 and
9:16 images at equal height into the drawable. The four-pixel gap is transparent
so the pane's background shows through; the drawable uses linear
`BGRA8Unorm`.

Menus and toolbars route commands to their owning window. Workspace restoration
uses NSDocument's standard document reopening and window restoration. Workspace
Inspector selection starts at nil and is neither encoded nor restored; the former
versioned selection key is ignored. AppKit owns frame and pane state.

Run `LDTXAppUIComponentTests` for directly constructed component, document lifecycle, saving, window, sheet, observation, and meter tests. These share a serialized MainActor parent suite and one Document Controller in a hostless AppKit test process. `LDTXAppUITests` launches the normal application for launch and main-menu smoke tests. The embedded XPC process-boundary test remains isolated in `LDTXAppXpcTests`. Generate project changes with XcodeGen and run builds and tests outside the sandbox.

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
monitor selection and YouTube selection remain path-keyed;
relocation cleanup for those fields is a separate change. Landscape and Portrait
master volumes and audio mute settings are independent. There is no mix
synchronization setting between the canvases.

The Workspace window uses the unified toolbar style. WorkspaceWindow owns its
NSToolbar, implements its delegate and handles target/action directly. Both
hosting controllers use `sceneBridgingOptions = []`; Workspace pane roots do not use
the SwiftUI toolbar modifier. Independent sheets retain their own controls. The fixed order is Sidebar, Stop, Start/Pause,
Screenshot, flexible space, the native `inspectorTrackingSeparator`, flexible
space, Apply, Inspector. Inspector stays at the trailing edge when Apply is hidden.
Output state updates existing item labels, images and
enabled state. Inspector collapse changes Apply's `isHidden` without removing
its item or the separator. Pane toggles directly change `isCollapsed`, without
animation. Toolbar customization and layout persistence are disabled.

Sidebar selection changes with pending edits preserve the current selection and
draft without displaying an error dialog. The store's non-persisted
`pendingEditsDidBlockSelection` callback asks the owning Window to open the
Inspector without animation and show a transient NSPopover anchored to Apply.
Repeated attempts reuse the popover. Apply, confirmed edits, and Window closure
dismiss it. Input validation uses the same non-modal popover; independent selection sheets display
their validation messages inline.

Apply requests Window-wide Submit through the non-persisted, Window-local
`WorkspaceStoreService.hasPendingSubmit`. The Window has one request observer.
Existing edit-validation registrations also supply change status and writeback;
OCR owns its seven input States, Video Layers owns transform drafts, and Master
Volume owns its numeric drafts. Submit first validates every pending owner. Any
validation failure reports the existing error and leaves all drafts and models
unchanged. Once every validation succeeds, each owner commits its values and
clears its change status. The request is cleared after either outcome, allowing
retry. Enter retains its existing local commit behavior; leaving a Master Volume
text field preserves its draft until Enter or Apply. Direct Bindings,
immediate controls, and independently confirmed sheets keep their behavior.

Apply is disabled with no pending changes, during output, or while a request is
pending, and hidden while the Inspector is collapsed. Unconfirmed changes block
Inspector selection, Program selection, and Content editor tab switches; assigning
the current selection or opening and closing panes is allowed and retains input.

Toolbar controls project the V4 recording session state. Pause drains
and finalizes the current output and leaves the session paused; the next Start
creates a new output session. Stop from paused returns to idle. Transition states
keep definition editing and output toolbar actions disabled, and finalization
failures remain visible. Pause state is not persisted in the Workspace package.

The Workspace Content pane uses an AppKit horizontal split above its AppKit
tabbed editor. `WorkspaceWindowController` owns the
`ProgramPairPreviewRenderer`, which reads the same Program runtimes used for
output. `ProgramCanvasPairedPreview` receives its Metal device and delegate,
centers a fixed 16:9 plus 9:16 pair with 12-point padding, and shows black when
frames are absent. It uses a standard `MTKView` with automatic drawable resizing.
Xcode previews use a dedicated delegate under `Content/XcodeHelpers` to draw
black canvases separated by a gray gap. Those previews pause the timed draw loop
and redraw on display invalidation without starting Program runtimes.
Preview clicks and accessibility actions update the window's transient
`isPortraitAudio` selection without changing document contents.

`configureAfterEstablished()` is a custom lifecycle hook called once after the
pane is attached to the window and the parent sizes are established. It calls
`layoutSubtreeIfNeeded()` before configuring size-dependent behavior.
The pane uses `setPosition` to
set the initial preview height to 280 points, then assigns `autosaveName` so
AppKit can restore saved divider configuration over that default. The pane does
not seed the layout by assigning view frames. Its higher holding priority
keeps its height when resizing the window, with the editor taking the size change
first. The content split uses AppKit default divider limits and collapse behavior.
`NSSplitView.autosaveName`, keyed by the definition envelope external
ID, lets AppKit save and restore divider configuration in application preferences.
`WorkspaceStoreService.externalID` holds that ID, and `WorkspaceContentPane`
constructs the autosave name internally. Divider
configuration is not stored in Workspace-local state. Shutdown pauses the MTKView, detaches its delegate,
and stops the renderer before shutting down the runtimes.

### Dynamic reference selection

Workspace Sidebar selection starts at `nil` and is not restored by AppKit. Explicit user selection and resource-addition selection remain window-local.

Physical assignments, VFX/OCR inputs, and stream keys show their current value separately from a Change sheet. Each sheet owns an initially unselected draft and applies it only after checking availability and edit permissions. Cancel leaves the model untouched. Unresolved or unavailable references remain visible without rewriting their saved IDs. Fixed enumerations retain their existing controls.

Monitor output selection is application-wide and belongs to SettingsApplet's
Audio tab. The current device is displayed separately from an initially
unselected candidate list. Selecting a candidate rechecks availability and
immediately persists it, without Apply or Cancel. System Default is an explicit candidate.
Device changes refresh the candidates without
rewriting the saved assignment. Discovery errors use the Settings Window's
presentError path, with repeated failures suppressed until recovery. Workspace
editors expose monitor volume and input routing, not output-device selection.
Monitoring uses Workspace audio devices and their shared gains independently of
Program selection. It remains available with no Programs; Program master volume
and mute settings affect output meters, not monitor routing.

Screenshot capture results appear in a transient NSPopover anchored to the
screenshot toolbar item. Successful captures show the saved Program image count
and the Landscape file icon and name; Portrait and VFX Source images remain saved but
are excluded from the popover. Clicking a file opens it in its default application;
dragging it provides a file URL for Finder or other destinations. Quick Look
generates the file icon asynchronously with `iconMode` enabled; the standard file
icon remains visible until a representation is available. Capture
failures show the error without modifying the output session's failure state.
Subsequent captures replace the message. Window closure closes the popover;
ordinary interaction dismissal is managed by AppKit.
The NSHostingController uses `.preferredContentSize` sizing, allowing SwiftUI's
ideal content size to size the popover without manually laying out or resizing
the hosting view. See Apple's [Use SwiftUI with AppKit](https://developer.apple.com/videos/play/wwdc2022/10075/).

SettingsApplet's Output tab configures the application-wide screenshots folder,
defaulting to ~/Pictures. Captures save there regardless of recording state and
also save identical images in the active local recording's Screenshots folder.
The toolbar folder action opens the global folder; the result counts images,
not duplicate copies. Recording and screenshots folder settings are independent.

### Video layer editing belongs to Content

The Editor vertically arranges MasterVolumeEditor, AudioMixEditor, and the
Landscape/Portrait Video Layers tabs. Each canvas has an NSTableView sized to
show all its rows and empty-state labels.
VideoLayersEditor has no internal scroll view; the Content pane scrolls all
editors together.
Transforms remain in the layer rows. MasterVolumeEditor owns both master volumes
and monitor volume controls. AudioMixEditor owns one Workspace-wide gain per input, independent Landscape/Portrait
mute controls, and local monitor controls. It has no canvas selector. Tab selection starts at
Landscape, is window-local, and does not select an audio canvas or Sidebar item.

The Content pane uses no SwiftUI hosting or Representable wrappers. Its standard
AppKit controls retain their default selection, background, and focus behavior.
Each layer operation copies the latest ProgramPreferences and submits the complete
value, preserving unrelated fields. Reordering submits the complete ID array and
must preserve the current membership. Tab changes require confirmed drafts; Program changes
discard field editors. Editors update from
`viewWillLayout()` using AppKit automatic Observation, without observation Tasks
or an externally invoked `stop()`.
Audio meters pause themselves when detached or when their window closes.

### Program selection in the Inspector

The first entry in Sidebar's WORKSPACE section is Programs. Selecting it opens
an Inspector containing a standard vertical SwiftUI radio-group Picker.
Content contains only the fixed previews and tabbed editor; Program selection
has no reserved row, horizontal scrolling, or custom layout sizing.

The Program candidates are static entries in the Workspace definition. The
Picker uses matching optional `UInt64` selection and tag values and reads the
resolved Program directly from model state. Its setter uses the existing
dispatcher; failed changes retain the model selection and report the error through
the Workspace standard error sheet. No independent selection state is kept. With an empty Program
array, the Inspector displays "No Program" instead of constructing a Picker.
The empty Content preview remains visible. Resolving a stale saved ID does not
rewrite it. Sidebar initially remains unselected.

The controller validates both canvas projections before updating the
Workspace-local selection. Selection leaves Sidebar and Inspector state alone.
Program changes are allowed during output, but not during start, pause, or stop.
Both existing runtimes and output audio mixes receive the selected Program's
configuration and preferences. Recording packages and publishing sessions stay
open across the change; output failures follow the normal finalization path.

Video layer tables always allow ordering, visibility, and transform editing,
including during output. Reordering uses the drag handle and is restricted to
a single layer from the same table. The table keeps
cell identity and unconfirmed transform text across ordinary model updates.

Each Video Component Inspector has separate Landscape and Portrait membership
Toggles and displays the selected Program name. Turning a Toggle on appends the
component to that canvas; turning it off removes the layer without deleting the
component or its saved preferences. The controls read current membership and
commit immediately through WorkspaceStoreService. They are unavailable without
a Program or while output is active. Submission revalidates the Program,
component, and output state. Content retains ordering, visibility, and transform
editing; it has no membership management button or sheet.
WorkspaceDocument allows only permutations of existing video-layer arrays during
output and retains the latest accepted order as its protected definition.

Recording folder overrides are stored per Workspace in `WorkspaceAppletData` local
state. They are selected with SwiftUI `fileImporter` and are not part of the
Workspace definition. Recording uses the local override, then the application
default folder, then the built-in default.

## Workspace state and cross-layer operations

WorkspaceDocument owns one Observable `WorkspaceStoreService`. It connects UI,
document, and runtime layers through both observable variables and method calls.
Simple state changes may assign variables directly; operations that require
validation or coordinated updates use methods. There is no separate UI Dispatcher.
The service weakly references `WorkspaceRuntimeActions`, implemented by the window
controller, and does not assemble capture, rendering, or output resources.
Disconnected runtime operations that need a result report an explicit error.

Content view controllers receive the service and construct their editors where
they are used. MasterVolumeEditor and AudioMixEditor have no reference back to
their parent pane. Each VideoLayersEditor directly owns its table, status,
Store connection and observation lifetime. There is one view
controller per canvas editor, with no additional editor controller wrapper. The window
does not refresh or operate individual editors. Dependencies and child controllers
are retained in init; view layout and configuration run in loadView. Initial
rendering uses current state, and observation does not force unloaded views to load.
Content does not require a shutdown cascade. AppKit owns observation tracking;
each meter manages its window notifications and drawing lifetime internally.
Program Preview and runtime shutdown remain explicit, and runtime shutdown
disconnects the service's runtime actions before releasing resources.

## Validation before saving

WorkspaceStoreService validates the definition and both canvas preference maps
with WorkspaceV4IntegrityValidator before a document save begins. Validation
collects independent issues with resource and canvas context into one localized
error. The Window displays the messages in its Apply popover and cancels the
save with `CocoaError.userCancelled`, suppressing AppKit error sheets.
A rejected save retains the edited model and leaves the existing package intact.
The asynchronous writer validates its captured snapshot again before any I/O.

Transforms and hidden flags may remain for detached layers, as long as their
Video Components still exist. Their values remain subject to normal validation.
Workspace Version stays 4 and Workspace Bundle Version stays 4.0.

### Rational32 numeric editing

Workspace V4 stores geometry, OCR parameters, and audio gains as `Rational32`
values. RGBA remains floating point. Rational32 decimal and fraction parsing
preserves the entered value; pixel coordinates are normalized using Rational32
arithmetic and restored without rounding. Audio gains are stored directly in
decibels, without a tenths multiplier. Missing scales resolve to identity while
an explicitly stored zero remains zero. Rendering and audio processing use
`Rational32.float` or `Rational32.double` at their numeric boundaries. Conversion
uses standard floating-point division: zero divided by zero produces NaN, and
nonzero values divided by zero produce signed infinity. These are the only custom Rational32 members;
constants use Protobuf `with`, text parsing and formatting belong to the UI
FormatStyle and ParseStrategy, and range checks belong to the integrity
validator.

A persisted Rational32 must have a positive denominator. Saving validates the
exact Rational32 ranges before writing the Workspace. Workspace Version remains
4 and Workspace Bundle Version remains 4.0.

## Workspace operation errors

Input validation uses `reportInputValidationError(_:)` and an Observation-ignored
Window callback; it never calls `presentError`. Known validation error types
reported through `reportError(_:)` are routed to this same callback. Enter,
Submit, navigation, save, and close preserve invalid drafts.

`WorkspaceStoreService.reportError(_:)` passes runtime operation errors to an
Observation-ignored closure installed by the owning WorkspaceWindowController.
Editors and Inspectors report failed commits through this boundary and retain
unconfirmed input and open editing sheets. Pre-submit validation and candidate
availability remain in the editing UI. Output-session failures and continuous
OCR diagnostics retain their existing state and display paths.

The Window Controller presents errors using AppKit `presentError`, targeting
the Workspace Window or its active editing sheet. It queues further errors
until the current presentation completes, and discards pending notifications
when the Window closes or shutdown begins. The callback captures the controller
weakly; UI components do not own the presentation lifecycle. Its `willPresentError`
customization applies only to the queued error's domain and code, combines the
failure reason with the recovery suggestion for AppKit's informative text, and
preserves the NSError domain, code, and other userInfo (including recovery metadata).

Native audio status notifications include an engine identifier and a failure
snapshot. The controller reads its own engine's initial monitor state, then
forwards subsequent notifications asynchronously to the main actor. An unchanged
monitor failure is reported once; recovery permits a later recurrence to be
reported again. Restart completions report orchestration errors, while native
hardware errors arrive through status notifications rather than that completion.
Capture synchronization similarly reports newly failed camera IDs together,
retains assignments, and clears failure state on successful retry. Device
enumeration retains its availability state and reports new failures.

Save preflight reports its aggregated LocalizedError through the non-modal
validation callback and completes with cancellation. Background snapshot
validation still throws before I/O. Runtime save failures retain standard
AppKit error presentation.

## Local YouTube authorization storage

Debug and Release builds check
`~/Library/Application Support/<application bundle identifier>/.YouTubeAuth`
once at application startup. If the file exists, Settings and Workspace use it
for both the OAuth client and AppAuth authorization state. Otherwise they use
Keychain. Distribution builds compile out file storage and always use Keychain.
Changing the file's presence requires restarting the application. Invalid or
removed files produce errors rather than falling back to Keychain.

To enable local file storage, create the application's Application Support
directory and an empty `.YouTubeAuth` file (or one containing `{}`) before
launching LDTX. Set the directory permissions to `0700` and file permissions to
`0600`. Import the
Desktop OAuth client JSON through the existing Account controls and authorize
normally. No storage-selection UI is added. The file uses a JSON envelope with
base64 `oauthClientJSON` and an `authorizations` dictionary keyed by client ID;
authorization values are base64 secure archives of AppAuth state. Writes are
atomic and set file permissions to `0600`. This development file contains
credentials, including refresh tokens, and is not encrypted by this mechanism.
