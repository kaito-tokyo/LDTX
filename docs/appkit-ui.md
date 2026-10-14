<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
SPDX-License-Identifier: Apache-2.0
-->

# Application and pane ownership

LDTX enters through `LDTXApp`, a SwiftUI `App`. Its body declares
`RecordPlayerScene`, `WorkspaceScene`, `SettingsScene`, and
`VisionProgrammerScene`. App initialization configures authentication storage.
DocumentGroup initializes and manages both Workspace and Record Player documents.
The App starts ApplicationDiagnostics from its scene-phase handler and installs
WorkspaceTerminationDelegate through NSApplicationDelegateAdaptor to wait for output shutdown.
SwiftUI owns the main menu and Scene presentation.
RecordPlayerScene is the first Scene and declares a DocumentGroup using the
macOS 27 Document API. WorkspaceScene also declares a DocumentGroup. SettingsScene supplies the standard Settings scene and VisionProgrammerScene supplies its training windows. Vision Programmer
is suppressed as a default launch window in LDTXApp, but opens normally in the
standalone test app.

LDTXApp groups these Scenes and installs VisionProgrammerCommands and RecordPlayerCommands on
the Group so the shared menu remains available across windows and without an
open document. Standard Open and editing commands come from SwiftUI.

WorkspaceDocument conforms to the macOS 27 Document API. DocumentGroup owns
creation, opening, standard Save and Close commands, autosaving, restoration,
and the document window. New presents an untitled editable Workspace; saving
chooses its location through the standard document flow. Info.plist registers
its content type without an NSDocumentClass.
Save As and Duplicate use the standard DocumentGroup behavior. SwiftUI manages
document filenames and window titles; saving does not derive the stored Workspace
display name from its package filename. An explicitly edited display name is preserved.
The external ID is assigned before the first save. Output controls stay disabled
until a document location exists, and the output controller also requires a
persisted runtime snapshot before starting.

Document owns workspaceSnapshot, WorkspaceStateService's editable values and UI
state, and file persistence. WorkspaceWindowController owns the runtime projection
coordinator and runtime resources, and receives the Document-owned StateService.
The NSViewControllerRepresentable receives Document and its Coordinator retains
WindowController. SwiftUI editing views receive StateService through Bindable.
Reconstructing the SwiftUI wrapper reuses the same controller and runtime.
The runtime controller holds the framework's window weakly and does not replace
its delegate or install its own restoration policy. Window closure finalizes
output and tears down capture, audio, Vision, and preview resources asynchronously.
Representable dismantling stops UI observation and initiates idempotent shutdown;
its Coordinator also initiates cleanup if released without explicit dismantling.

The SwiftUI App connects a termination-only `NSApplicationDelegateAdaptor`.
Quit returns `terminateLater` while any Workspace controller is alive or its
shutdown is running, and replies only after all controllers finish. This includes
controllers whose windows have already closed. Shutdown failures are retained
until they can be presented before cancelling termination; another Quit may then
proceed. Standard document save confirmation remains owned by SwiftUI.
The ordinary-close presentation acknowledges its queued shutdown failure. If Quit
is already waiting for shutdown, termination owns that presentation instead.

The Representable Coordinator registers Undo/Redo for content changes, including pending
model selections, to preserve DocumentGroup's unsaved-change and autosave tracking.
Workspace Undo and Redo menu commands and their keyboard shortcuts are temporarily
disabled while a Workspace scene is active. Other scenes retain their standard
commands. Undo registration itself remains enabled for document change tracking.
UI selections and runtime results are not undoable document
changes. Reads and confirmation synchronization do not register Undo. Saving
captures Document's StateService values without requiring a represented editor.
Removing the UI does not discard editing values or prevent saving. Snapshot
capture reflects content into Document; Writer validates it before writing.
Write failure preserves that content as unsaved. Edits made during writing
remain in StateService.

Reader and Writer use WorkspaceV4Bundle directly as their Snapshot. Reader does
not attach its source URL to that content. Applying a read replaces only the
Document's workspaceSnapshot; it never restores an earlier URL or calls UI or
runtime update hooks. The Representable Coordinator observes read generations
and directly assigns StateService fields using full overwrite. Full overwrite replaces all document
values and model URLs, while preserving UI and runtime status. The alternative
URL-only operation changes only URLs for IDs already in StateService; it preserves
other edits and does not add or remove models. There is no implicit merge. The
Coordinator observes content and URL changes for Undo baselines and UI routing.
WindowController independently observes content, URL, persistence notifications,
and output state. It adopts persisted runtime content while idle and defers that
adoption during output. Document does not keep a second runtime bundle.

UI receives the document explicitly as a weak WorkspaceDocumentContext whose
fileURL is supplied by URLDocumentConfiguration. No document environment box is
used. Applet-local state uses the transient URL until the framework assigns a
formal URL. URL changes copy local state and update persistence routing. The
Dock badge observes weakly registered Workspace documents and remains active
while any Workspace has active output.

The Workspace sidebar owns one SwiftUI `.sheet(item:)` presentation for adding
input devices, video components, and OCR or Create ML image-classification visions. The window injects its device
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
Each editor owns its Observation task and reads the shared WorkspaceStateService.
The editor stack is the vertical NSScrollView's document view directly. Its
flipped coordinates keep the controls at the top, and its width tracks the
viewport without an intermediate container. Reducing the lower pane height scrolls the controls rather
than requiring the pane to fit all editors at once.
Output and canvas settings, including their supporting types and helpers, live
under `Sources/Applets/Workspace/UI/Inspector`. Physical-device assignment is
owned by the video and audio input Inspectors, which share
WorkspacePhysicalDeviceField for selecting, clearing, and refreshing devices.

WorkspaceViewController configures its NSSplitViewController directly with hosted SwiftUI sidebar and
Inspector panes and an AppKit WorkspaceContentPane in the center.
Record Player lives under Sources/Applets/RecordPlayer in the
LDTXRecordPlayerApplet module. Its small implementation uses a flat directory.
RecordPlayerDocument conforms to SwiftUI's macOS 27 Document API and is
Observable. Its URLDocumentConfiguration supplies the recording location, and
the Document owns in-memory marker edits and the playback model. DocumentGroup
opens existing recordings with allowCreating set to false and creates their
SwiftUI roots directly, without a custom WindowController. The root uses
NavigationSplitView, an inspector, a toolbar,
and alerts. VideoPlayer supplies playback controls; marker navigation performs
exact seeks through the Document-owned model. Inspector commands use the focused
SwiftUI binding rather than finding a WindowController. Document release stops
playback; rebuilding the UI does not stop or recreate the playback model.
Marker additions, replacements and deletions register undo actions with the document's
environment UndoManager. DocumentGroup manages saving and autosaving using
SwiftUI's standard document commands.
Markers are auxiliary information without strict conflict detection. A coordinated
save atomically writes individual marker files, then reads the disk contents under
the same coordination. The Writer uses the coordinated staging package supplied
by DocumentGroup and does not start a nested file-coordination operation.
Deletion requests carry in-memory tokens. The Writer compares them with SwiftUI's
previous successfully written snapshot, so an acknowledged deletion is not
replayed against an externally recreated filename. Undo followed by Redo creates
a fresh deletion token; a failed write does not acknowledge a token.
Deletions resolve disk filenames by canonical timestamp, so filename reconciliation
during a previous save does not leave a marker behind.
Subsequent reader snapshots update the observable marker
list while preserving edits made since the previous snapshot. Disk-only
markers and unknown files remain intact; media and required metadata are untouched.
There is no baseline comparison, whole-directory replacement, or rollback. A failed
write or reread preserves the document's edits and change state for retry, even if
some files were already written. Timestamp identity uses millisecond precision and
reuses the first existing filename in filename order. Other same-time files remain
untouched. Existing empty notes can be saved; new empty notes are rejected.
Deletion requires a separate confirmation and updates only the in-memory marker
list. Undo restores the removed marker; Redo removes it again. The captured save
snapshot includes explicit deleted filenames, and Writer removes only those files
from its coordinated staging copy. Other pending edits and externally added
markers are retained. Missing files count as deleted. Active recordings reject writes.
The reader and writer perform URL-based I/O off the main actor. The writer
requires an existing valid recording package at its destination. DocumentGroup
prepares and replaces the staging package; the writer updates only marker files.
The applet Commands do not replace the standard Close, Save, or related document commands.
SwiftUI owns window closing, document presentation, and restoration. Playback
stops when the Document is released; UI disappearance alone does not stop it.

Document captures protobuf documents and model source URLs
on the main actor and reflects them into Document without validation.
The DocumentWriter validates the snapshot off the main actor before writing. It copies native
model files and package directories under their assigned IDs and performs package I/O off the main actor, using DocumentGroup's coordinated
staging destination without nesting a file coordinator. It preserves unknown
files and past models. Save failure leaves the current edits intact.
Snapshots exclude edits made after their capture.

Writing the staging package alone does not update runtime definitions. After
URLDocumentConfiguration reports a committed URL/modification date, WindowController
reads the formal package independently and adopts that
persisted Definition for ProgramRuntime and Vision. Newer edits and model
selections remain pending. Preferences can reach the runtime immediately.
External Reader snapshots overwrite the editing documents through the full
synchronization mode. The runtime independently adopts the on-disk Definition
when its execution state permits that update.

Invalid content prevents snapshot confirmation. The framework
handles its normal unsaved-change review; pane visibility does not own runtime
lifetime. Output uses the last successfully persisted Definition and requires a
formal document URL.

Workspace starts with a 240-point sidebar, 480-point content pane, and 340-point inspector. The sidebar and inspector can be toggled from their toolbar buttons; each retains its expanded width and does not collapse automatically when the window is resized. Content absorbs window resizing first. Content does not extend beneath the side panes. The inspector has a maximum width of 480 points, while the sidebar has no application-defined maximum.

WorkspaceWindowController constructs and retains the Program preview's single
`MTKView`, then passes the configured preview to the Content view controller. A
`ProgramPairPreviewRenderer` supplied as its delegate reads the latest
`ProgramFrame` from the Landscape and Portrait runtimes and draws the 16:9 and
9:16 images at equal height into the drawable. The four-pixel gap is transparent
so the pane's background shows through; the drawable uses linear
`BGRA8Unorm`.

Menus and toolbars route commands to their owning window. Workspace restoration
uses DocumentGroup's document reopening and window restoration. Workspace
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
Model, Service, Store, or UI subdirectory. Workspace has no Interface umbrella
module: consumers import their dependencies directly. Shared state enums live
in Model; runtime protocols and Program resolution live in Service. XcodeGen generates the
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
subsequent canvas loads use the current document URL. DocumentGroup manages document
access, without a separate security-scope lifetime or application move observer.
Marker identity is a package-relative filename, never an absolute URL. Save
writes the in-memory snapshot at the URL supplied to the DocumentWriter without
deleting unknown files. Successful Reader snapshots always replace marker contents and discard
unsaved additions, deletions, and note edits, including during the standard Revert operation.
Access failures preserve
pending marker edits and are reported through the existing error paths.

RecordPlayerDocument is observable and is the sole owner of marker contents.
Player panes observe its markers through an explicitly supplied weak Document reference; playback
models contain no marker copies or editing callbacks. Marker edits enter through
the document methods, which register marker editing with the UndoManager supplied
by DocumentGroup. Lifecycle bookkeeping is excluded from Observation.
Missing documents disable marker actions. Save synchronization and in-memory
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

The Workspace window uses the unified toolbar style. WorkspaceToolbarCoordinator
owns the NSToolbar and its items; WorkspaceViewController configures labels and
target/action and attaches the toolbar to the framework window. Pane roots do not
use the SwiftUI toolbar modifier. Output state updates existing labels and images.
The toolbar has no Apply item or Inspector title. Sidebar and Inspector use the
split view controller's standard toggle actions. Toolbar customization and layout
persistence are disabled.

Editors write representable values directly to WorkspaceStateService. OCR ROI
uses the same bound RegionOfInterestEditor as Scene Detector ROI. Master-volume
and transform fields write numeric values as they change; incomplete numeric text
remains local to the control. There is no separate WorkspaceEditingState, Apply,
or window-wide Submit. Inspector, Program, and tab selection are not gated by
pending drafts. Saving validates the authoritative documents and preserves edits
on failure; Definition changes reach execution only after persistence succeeds.

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
`WorkspaceStateService.externalID` holds that ID, and `WorkspaceContentPane`
constructs the autosave name internally. Divider
configuration is not stored in Workspace-local state. Shutdown pauses the MTKView, detaches its delegate,
and stops the renderer before shutting down the runtimes.

### Dynamic reference selection

Workspace Sidebar selection starts at `nil` and is not restored by AppKit. Explicit user selection and resource-addition selection remain window-local.

Physical assignments, VFX/OCR inputs, and stream keys show their current value separately from a Change sheet. Each sheet owns an initially unselected draft and applies it only after checking availability and edit permissions. Cancel leaves the model untouched. Unresolved or unavailable references remain visible without rewriting their saved IDs. Fixed enumerations retain their existing controls.

Monitor output selection is application-wide and belongs to SettingsScene's
Audio tab. The current device is displayed separately from an initially
unselected candidate list. Selecting a candidate rechecks availability and
immediately persists it, without Apply or Cancel. System Default is an explicit candidate.
Device changes refresh the candidates without
rewriting the saved assignment. Discovery errors use the Settings Scene's
SwiftUI alert, with repeated failures suppressed until recovery. Workspace
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

SettingsScene's Output tab configures the application-wide screenshots folder,
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
Each layer operation copies the latest ProgramPreferences and updates the complete
value, preserving unrelated fields. Reordering submits the complete ID array and
must preserve the current membership. Tab and Program changes need no Submit;
Program changes discard incomplete local text. Editors update from
`viewWillLayout()` using AppKit automatic Observation, without observation Tasks
or an externally invoked `stop()`.
Audio meters pause themselves when detached or when their window closes.

### Program selection in the Inspector

The first entry in Sidebar's WORKSPACE section is Programs. Selecting it opens
an Inspector containing a standard vertical SwiftUI radio-group Picker.
Content contains only the fixed previews and tabbed editor; Program selection
has no reserved row, horizontal scrolling, or custom layout sizing.

The Program candidates are static entries in the Workspace definition. The
Picker uses matching optional `Int64` selection and tag values and reads the
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
cell identity and incomplete transform text across ordinary model updates.

Each Video Component Inspector has separate Landscape and Portrait membership
Toggles and displays the selected Program name. Turning a Toggle on appends the
component to that canvas; turning it off removes the layer without deleting the
component or its saved preferences. The controls read current membership and
commit immediately through WorkspaceStateService. They are unavailable without
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

WorkspaceWindowController owns one Observable `WorkspaceStateService` for editable
values and UI/runtime status. Document owns confirmed content separately.
Simple state changes may assign variables directly; operations that require
validation or coordinated updates use methods. There is no separate UI Dispatcher.
The service does not reference runtime actions or assemble capture, rendering,
or output resources. UI owners receive runtime actions through weak providers.
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

Reader and Writer use WorkspaceBundleValidatorV4 in LDTXWorkspaceBundleFormat
as their content gate. Validation collects independent field-level issues,
including model resource references, into one error containing the diagnostic
array. Invalid values are rejected without normalization. The document framework
presents every diagnostic together; Snapshot capture itself does not validate.
A rejected save retains the edited model and leaves the existing package intact.

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

Save validation errors are surfaced by the document framework. Runtime operation
errors use WorkspaceWindowController's queued error presentation. Editors and
Inspectors receive the error-reporting boundary explicitly or through the SwiftUI
error environment. Output-session failures and continuous OCR diagnostics retain
their existing state and display paths.

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

## Create ML Image Classification Inspector

The Add Vision sheet selects OCR or Create ML Image Classification and requires
an explicit Video Component selection. Classification Visions have their own
Sidebar selection and Inspector with name, Video Component, update interval,
and ROI settings. Name, input, interval, and ROI use direct Bindings to the Store.
An invalid ROI remains in the Store until corrected and is rejected on save.
Editing is disabled during output.
The Inspector includes Default and Output Active previews. Classification
settings are validated and saved in Workspace V4. Model import and classification
execution are separate work; this UI does not select or compile a model.

OCR and Create ML Image Classification Inspectors select their input Video
Component with a menu Picker. Unassigned clears the reference; a missing current
reference appears as Unavailable until the user chooses a replacement. Selection
changes synchronize Vision immediately, and output activity disables editing.

Physical device, timing master, and stream-key assignments use inline menu
Pickers rather than selection sheets. Physical-device and stream-key selections
retain their availability checks before committing. Missing assigned values
remain visible as Unavailable; clearing an assignment uses Unassigned, Automatic,
or Host Clock as appropriate.
