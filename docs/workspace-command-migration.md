<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Workspace command migration

This implementation increment follows the v0.2.7
[plan](https://chatgpt.com/space/page_7b9fe4feca208191af6c143e5c10b6de) and
subsequent confirmed decisions. All six Coordinator resource operations are
connected. Subsequent hardware and interactive verification is recorded below.

## Recorded validation summary

The final targeted hostless run passed 68 tests with zero skipped: Easy 19,
Medium 4, Hard 2, UI Component 34 and Output 9. Swift strict formatting, native
clang-format checks and git diff checks passed. The normal unsigned Debug app
build passed again after all temporary startup instrumentation was removed.
These are selected regression tests, not a claim that the entire repository test
matrix or every hardware configuration was exercised.

The subsequent local UI runs verified saved reconstruction, actual recorded
Program content switching, GCNeo video/audio assignment and reassignment,
recording/finalization, active-output assignment/Close restrictions, save-review
cancellation and independent Workspace closure. Starting Stop/Close used the
bounded Coordinator-preparation gate described below. A subsequent UI run also
verified Stop and Close inside native startup using the bounded native gate
recorded in the final section. A hostless test separately exercises native
dual-output startup interrupted by Stop. The initial
FileProvider/iCloud response stall remains unexplained; its absence under changed
local conditions does not establish an OS defect or a repaired product bug.

## Queue and failure contract

Each Coordinator owns an independent WorkspaceCommandQueue backed by its own
EventTaskQueue. Media-processing queues remain resource implementation details.
A running operation retains its completion until its asynchronous work finishes.
No Workspace queue waits on another Workspace queue.

On execution failure the dispatcher prevents successors from executing, awaits
minimal consistency repair, confirms Stall, increments its retryNumber once,
and publishes one aggregated error before completing failed/rejected results.
Stop has no notification-priority exception. Its error warns output may still be
running; Close guidance mentions optional Force Quit and possible data loss.
Input validation precedes QueueItem creation and does not cause Stall.

Discarded items never return. Explicit user reapplication joins the retired
queue and opens an empty queue. It preserves retryNumber and performs no replay.
Requests arriving during repair wait outside admission, then receive rejection.
Reconciliation callbacks must not enqueue and await their own queue.
WorkspaceCommandState includes the Workspace-owned retryNumber in value equality;
there is no separate dirty flag, desired-value store, revision, or rollback history.

## Connected operations and completion boundaries

| Command | Implemented path and awaited boundary |
| --- | --- |
| ReconstructRuntime | Validate canonical input before admission; adopt definition and VariableStore; await Capture, Audio and model preparation. Explicit successful native Save can reapply unchanged saved values after Stall. Automatic observation cannot reopen Stall. |
| UpdateDeviceAssignment | Picker, resource addition and assignment observation enter the queue. Await structured Capture results and Audio restart result before completion. Unavailable cameras alone are successful assignments; actual start/configuration errors fail the command. |
| SwitchProgram | Await both enabled output audio mixers. On failure restore only the previous selected ID and projections, preserve edits and output failure/cleanup, and do not restart output. |
| StartOutputSession | Await model preparation, canonical validation and service startup result. A failed started operation awaits cleanup; a discarded pending Start does not stop an existing session. |
| StopOutputSession | Stop/Pause await subscription/media/archive drain and finalization. Stop during Start queues behind Start without interrupting it. Current stop errors are distinct from retained prior UI failure text. |
| CloseWorkspace | Reject during active output or admitted Start. Queue after prior work, await inference/Vision, output drain, preview GPU completion, runtime rendering, Overlay rendering (including retired overlays), component rendering, Capture and Audio stop. Verify stopped native coordinators before marking closed and releasing registration. |

OutputActive permissions are confirmed: Reconstruct, assignment, Start and Close
are forbidden; Switch and Stop are allowed. Close during Start is now confirmed
forbidden: the user must wait for Stop completion before closing. Rejected input
neither stops output nor changes the retry sequence.

Capture publishes status before callbacks. Structured results separate missing
hardware, per-camera execution failures and coordinator lifecycle errors. Audio
restart returns its current result; cancellation is joined before monitor stop.
Stop returns current finalization errors even when their text matches an older
failure, while successful cleanup preserves the old failure display.

Preferences remain synchronous values/snapshots. Monitor gain changes use a
native values-only API: they update existing routes without constructing inputs,
rebuilding missing monitors, or rereading the output device. Output-device
preference notifications filter changes and ask the Coordinator to enqueue
assignment work; they no longer rebuild directly from UserDefaults callbacks.
Monitor topology toggles use UpdateDeviceAssignment and require inactive output.
Only an explicit toggle can open new admission after Stall. There is no
Preferences command. Internal renderer frame loops remain independent; command
completion is not a promise that the first new frame has appeared onscreen.

## Legacy-path audit

- Program deletion edits the document only. It no longer switches the applied
  selection or restarts resources before the saved definition is reconstructed.
- Monitor topology and the compatibility Capture callback enter the Workspace
  queue. Audio restart joins its predecessor instead of cancelling accepted work.
- Requests waiting through repair retain their admission retryNumber. Opening a
  new queue cannot admit a request from the failed generation.
- Normal native Window close reviews unsaved changes before requesting resource
  cleanup. Cancellation preserves the runtime; successful drain precedes the
  native close request. A delegate proxy forwards other Window events.
- Application termination validates Close admission before and after save waits.
  Its final resource pass collects results once, preserving independent Workspace
  execution, and cancels termination on failure instead of retrying forever.
- Native output faults retain service-local containment. Start joins interrupted-start cleanup; Program reconfiguration now also joins an already running or concurrently started failure drain before returning.
- Closed state and registration release occur only after successful drain. Failed
  or discarded Close leaves the document open, preserves Stall and gives Force
  Quit guidance. A new explicit Close is a new item, never restored old work.

## Verification limits

Hostless tests cover queue sequencing and repair, concurrent re-admission,
Workspace isolation, startup Stop FIFO, Close rejection and discard, native save
review cancellation and drain ordering, monitor restart joining, Overlay render
drain, and existing recording/archive completion. No live app, camera, recording,
streaming, or interactive termination was launched. Native programmatic
NSWindow.close/NSDocument.close bypass user review by AppKit design; their
willClose fallback still requests the same Coordinator Close operation and never
marks a rejected operation closed.

Workspace format versions remain the integer 4 and string 4.0. No persistence
format or Undo history changes are introduced. No automatic correction is added;
users explicitly reapply after an error.

## Interactive validation attempt (2026-10-20)

The user subsequently authorized actual application validation. The current
branch's Debug app from `/tmp/ldtx-v027-derived/Build/Products/Debug/LDTX.app`
was copied to `/tmp/LDTX-v027-UI-Test.app` with an isolated Bundle ID
`tokyo.kaito.ldtx.v027uitest`. Only the copied Info.plist identifier changed;
the executable SHA-256 was
`6a02899be9e4e0360786dc7883936276f0f043910e854dad931c9bae61f77026`.
Its displayed build version remains 0.2.6 (1); this is a development build,
not a published v0.2.7 release.

The existing `/Applications/LDTX.app` process (PID 48713) and its user Workspace
were inspected read-only. Its toolbar showed Start enabled and Stop disabled.
It was not closed, stopped, or modified.

The isolated process (PID 92112) opened its initial Open panel. Cancelling that
panel and creating a new Workspace succeeded. Opening Programs and adding the
first Program succeeded. A combined second-Program-add and Cmd-S action timed
out, so completion of either action is uncertain. One subsequent AX observation
also timed out. No new permission request was observed or accepted; no external
stream, recording, or authentication change was initiated.

A three-second sample captured the main thread inside NSDocument's
`_checkAdvisoryAutosavingSafety`, through FileProvider trash-URL checking, blocked
in `FileProviderOverride -> getxattr`. This is observed evidence, not a confirmed
root-cause diagnosis or a proven transactional-queue defect. Evidence is saved at
`/tmp/ldtx-v027-ui-test/hang-save.sample.txt`.

The UI attempt stopped after this bounded diagnosis. SIGTERM ended only the
isolated PID 92112; a process check confirmed that it exited and PID 48713
remained running. No code changes were made in response to the inconclusive
hang. Program switching, saved reconstruction, assignment, actual output
Start/Stop, active-output prohibitions, starting Stop FIFO, Close rejection and
post-Stop Close, save-review cancellation, and two-Workspace independence remain
unverified through actual UI. Their hostless test results above remain separate
from this interrupted interactive attempt.

### Read-only diagnosis of the interrupted UI attempt

No additional launch, reproduction, attachment or process termination was
performed for this diagnosis. The existing sample and recorded subsystem logs
were read. Both the main thread's NSDocument advisory-autosave safety check and
the background Document Recents bookmark insertion spent every sampled stack at
FileProvider's trash-URL lookup, ending in getxattr. The sample has no syscall
arguments, so its exact target path and extended-attribute name are unknown.
Rendering logs continued through 08:35:13, supporting a localized document/UI
metadata stall rather than proving a complete runtime or command-queue deadlock.

The copied Info.plist differs from the build only in CFBundleIdentifier and the
executable hashes match. The iCloud container declaration is still
`iCloud.tokyo.kaito.ldtx.LDTX`. The new preference domain's local-state dictionary
contains the path
`/Users/umireon/Library/Mobile Documents/iCloud~tokyo~kaito~ldtx~LDTX/Documents/Untitled 2.ldtxworkspace`.
Its navigation bookmark also contains that iCloud Documents directory. Thus the
new document acquired an iCloud-associated URL despite the separate Bundle ID;
the test was not fully isolated to local /tmp storage. This is the strongest
identified path candidate, not proof of the getxattr argument or of a completed
disk write. That iCloud path was not further accessed or modified during diagnosis.

WorkspaceDocument's snapshot/Writer model is unchanged from HEAD. Manual saving
still uses the existing native NSDocument activity/save-delegate bridge; the new
hook only requests reconstruction after didSave reports success. The sampled
stack is an AppKit change-count/autosaving check, not that success callback or a
WorkspaceTransactionalCommand stack. Cmd-S delivery itself remains uncertain
because the second add and save were bundled in the timed-out UI tool call.

Supported candidates are FileProvider metadata latency on the new iCloud URL,
and the copied app's unchanged iCloud declaration influencing default document
placement. Neither an OS defect nor an application regression is established.
The next discriminating check, when separately authorized, is to pre-create a
valid test bundle entirely in a verified local directory and open that exact
file in an isolated test build with its iCloud document declaration removed in
test packaging only. Confirm its canonical URL before editing, perform one edit
at a time and only then one Save. Do not disable autosave, alter production
preferences, or patch the queue to conceal this unproven cause.

### Authorized local comparison and continued UI validation

The test copy's NSUbiquitousContainers declaration was removed; no production
Info.plist, entitlements, cloud settings, or user documents were changed.
WorkspaceBundleWriterV4 from the same compiled frameworks pre-created Local-A
and Local-B under `/tmp/ldtx-v027-ui-test/Workspaces`. The actual UI URL for A was
`file:///private/tmp/ldtx-v027-ui-test/Workspaces/Local-A.ldtxworkspace/` and B
showed the corresponding Local-B URL. The test app restored the first attempt's
Untitled 2 in the background; it was not used for the comparison edits.

Observed UI results, with edit and save actions separated:

- Opening local A, adding one Program and Cmd-S succeeded without a timeout.
  Adding a second Program, saving, and selecting Program 2 also succeeded.
- Recording Folder was explicitly set to `/tmp/ldtx-v027-ui-test/Recordings`.
  Enable Recording and Record Landscape were enabled and saved. YouTube remained
  off. Start changed to Pause and enabled Stop; output settings were disabled.
- Closing A during output displayed the expected Stop-before-close and possible
  Force Quit/data-loss guidance. Dismissing it left output running.
- Program switching remained enabled during output; selecting Program succeeded.
  Program Add/Rename/Delete were disabled while output was active.
- Local B opened and closed while A continued to display Pause/Stop. A then
  stopped normally and displayed Start with Stop disabled.
- Adding a synthetic Test Pattern used the resource-addition/device-sync entry
  without camera or microphone access. Enabling its Landscape layer and saving
  produced the visible test-pattern preview, confirming saved runtime adoption.
- Save As Cancel kept A's URL and allowed subsequent Program selection.
- A closed normally after Stop. During normal application termination, the
  restored first-attempt test document produced a save confirmation. Cancel
  preserved the document and Programs navigation remained responsive.
- A subsequent termination saved that test document locally as
  `Workspaces/Recovered-First-Attempt.ldtxworkspace`, then exited PID 92607 normally.
  The original production PID 48713 remained running. No process was killed in
  this comparison, and no new permissions or authentication changes were made.

The local recording package is
`Recordings/LDTX20261020T084016.714.ldtxrecord`. It contains `.finalized`; ffprobe
read a 47.16-second MP4 with H.264 1920x1080 and AAC tracks, size 35,008,931 bytes.
This run used no physical input devices. The recording preceded addition of the
visible test-pattern layer, so it does not demonstrate visually distinct Program
content switching in the recorded video.

The original response stall did not recur under the changed conditions. This
single comparison changed both cloud declaration and document location and does
not establish which factor caused the original stall or rule out a transient
FileProvider issue. No product-code fix was justified or made.

Still unverified in actual UI: physical-device reassignment, permission-protected
capture, starting-state Stop FIFO/Close rejection (startup completed too quickly
to observe that state reliably), and an actual recorded first-frame content
change between Programs. No slow-start or fault injection was attempted.
Hostless tests separately cover those command-state and completion contracts.

### Recorded nonempty Program content switch

A further authorized local QA run saved two nonempty Landscape Programs in
Local-A: Program A contains Test Pattern and Program B contains a solid RGB
(0.2, 0.2, 0.2) fill. Screenshots verified the patterned and uniform-gray previews
before recording. The same local-only app copy and explicit local output folder
were used; no physical devices, permissions, external streams or product-code
changes were involved.

UI click intervals were recorded in UTC:

| Operation | Before click | After click |
| --- | --- | --- |
| Start A | 2026-10-19T23:47:32.804Z | 23:47:32.828Z |
| Switch B | 2026-10-19T23:47:36.938Z | 23:47:36.971Z |
| Switch A | 2026-10-19T23:47:41.679Z | 23:47:41.709Z |
| Stop | 2026-10-19T23:47:46.504Z | 23:47:46.518Z |

The resulting `Recordings/LDTX20261020T084732.878.ldtxrecord` contains
`.finalized` and a 13.633333-second H.264 1920x1080/AAC MP4. Extracted frames at
2, 6 and 11 seconds visibly show pattern, gray and pattern respectively. Full
frame luma-range analysis locates the changes at media PTS 4.050 seconds (gray)
and 8.783333 seconds (pattern), consistent with the operation sequence. This
confirms actual recorded A-to-B-to-A content changes, without asserting an exact
cross-clock input-to-frame latency.

Default ffmpeg null-output timing generated a nonmonotonic-output-DTS warning
when converting the stream to its guessed frame-rate timebase. Direct inspection
found no nonincreasing video packet PTS or DTS. Decoding both streams with the
source 1/600 video timebase produced an empty error log. No file-timestamp defect
was established by that analyzer warning.

Evidence is under `/tmp/ldtx-v027-ui-test/content-switch/`: `operations.json`,
`aba.png`, `transitions.json`, `video-packets.json`, and
`decode-native-timebase.stderr`. The test Workspace closed and the test app
exited normally; the existing production PID 48713 remained running. The earlier
recorded-content limitation is resolved. Physical assignment and starting-state
Stop/Close remain unverified through actual UI; no delayed-start test was added.

### GCNeo hardware validation and return to the user Workspace

The user authorized temporary release and restoration of the production GCNeo
assignment. At the start of this attempt, the earlier production PID was no
longer present: the production app was PID 93581 with its initial Open panel and
no open Workspace. No active recording or stream was interrupted, and no
production assignment needed to be edited or cleared. The isolated test app was
PID 93602 and used the new writer-created local fixture
`/private/tmp/ldtx-v027-ui-test/Workspaces/Local-GCNeo.ldtxworkspace/`.

Both camera and audio lists contained Elgato Game Capture Neo. The test VFX source
and audio-input resource were assigned to it, saved, and used without accepting
any new permission prompts. Initial video startup took about 16 seconds: existing
logs show a 1920x1080/60 request at 09:06:12, capture running at 09:06:27.823 and
the first accepted video sample at 09:06:28.370. The initial gray preview was
therefore not treated as evidence of no signal or failure. A later screenshot
confirmed the live game image.

Recording was restricted to `/tmp/ldtx-v027-ui-test/Recordings`, with Landscape
recording enabled and YouTube off. During recording, both video and audio
physical-device Choose buttons were disabled. Pause completed and enabled the
buttons. Audio and video were individually changed to Unassigned and then
reassigned to the same GCNeo through the UI. The game image and nonzero audio
meters returned. Stop then completed, the test Workspace closed, and the test
app exited normally; a process check confirmed PID 93602 absent before the
production Workspace was reopened.

`Recordings/LDTX20261020T090917.556.ldtxrecord` contains `.finalized` and a
21.385-second H.264 1920x1080/AAC 48kHz stereo recording. Extracted frame inspection
confirmed the game image. Both streams decoded with zero errors using the source
video timebase; audio was non-silent (overall peak -10.642604 dBFS, RMS
-22.916908 dBFS). This establishes received/recorded signal and decodability,
not a calibrated fidelity or audio/video synchronization measurement. Evidence
is under `/tmp/ldtx-v027-ui-test/gcneo/`.

Finally the production app reopened the original Unite-v0.2.4 Workspace without
editing or saving its content. CaptureVideo still selected Elgato Game Capture
Neo, as did the existing GCNeo audio resource. The original GCNeo gain -16 dB,
Monitor enabled, master volumes 0 dB, monitor volume -16.5 dB, and HyperX gain
1.9 dB were preserved. Variables view was restored; screenshots confirmed the
game image and nonzero GCNeo audio meters. Production output remained stopped.
There was no hang, external stream, driver change, product-code patch, commit,
push or PR. The physical-device assignment/reassignment UI coverage gap is now
resolved; starting-state Stop/Close remains the separate actual-UI limitation.

### Starting-state Stop and Close with bounded UI instrumentation

The user authorized the remaining starting-state checks, including a controlled
wait if natural startup was too short to observe reliably. A separate app copy
`/tmp/LDTX-v027-Start-State-QA.app` was built with temporary instrumentation in
Coordinator.startOutput. The wait begins immediately after Coordinator/UI state
becomes starting and output-active, before model preparation and native output
service startup. At that exact point native recordingSession.state is idle.
Thus this exercises the real UI during the Coordinator's admitted Start command,
not a simulated button handler, while distinguishing the native startup phase.

The asynchronous wait polls a test-only hold file and has a hard 45-second
ContinuousClock deadline. Removing the file releases it. Both runs were explicitly
released before the deadline; neither timed out. No driver, permission, network,
physical device or existing production app state was changed. Local-A used only
its saved Test Pattern/Solid Color resources and its explicit local output folder.

Stop run:

1. UI showed Start disabled and Stop enabled; event log confirmed ui=starting,
   native=idle with the Start command retaining queue ownership.
2. Clicking Stop logged stop_requested in that same state. UI remained starting;
   no Stop operation or native startup cancellation occurred during the wait.
3. Releasing the hold led to start_completed (recording), then
   stop_operation_started (recording), then stop_completed (idle), in that order.
   UI returned to Start enabled/Stop disabled.

Close run:

1. A separate held Start again showed the same starting state.
2. Clicking the native close button logged close_validation in ui=starting,
   native=idle and displayed the expected Stop-before-close/data-loss guidance.
3. Dismissing the alert preserved the original Workspace URL and held starting UI.
4. Releasing the hold allowed Start to finish. Stop then completed, and a new
   Close succeeded once in idle state. The test app exited normally; process
   inspection confirmed only production PID 93581 remained.

This complements the earlier deterministic hostless FIFO/rejection tests and
natural real-device/output tests. It does not claim that a human-timed click
landed inside the shorter native AVFoundation startup subphase. The test window
was deliberately widened during the Coordinator's preparation phase.

The source was restored byte-for-byte immediately after the instrumented build,
verified against a saved backup (SHA-256
`e8f17a491ff1560dc9683eb0e438edd2533a1e1c1a657f2aaed5825b7a1fb9df`).
A normal Debug rebuild subsequently succeeded, removing instrumentation from
the ordinary build products as well. There is no retained product-code delay or
new test hook in the repository. Evidence, including the temporary instrumented
source, build logs and event timestamps, is in
`/tmp/ldtx-v027-start-state-qa/`. No commit, push or PR was created.

## Follow-up: native startup completion and FileProvider diagnosis

Review of native dual-output startup found a reproducible completion defect:
when stopped child sessions reject Start synchronously, the second child callback
and the final readiness check can both invoke the caller's completion. This
could resume a caller's checked continuation twice. The failure was reproduced
before changing production code: two of the three enabled-canvas combinations
returned two completions instead of one. The aggregator now claims completion
before notifying its caller, including for synchronous failures.

The new regression covers Landscape only, Portrait only and both canvases. A
second hostless integration test starts both native output pipelines and calls
Stop before yielding MainActor, while their asynchronous mixer completions are
pending. It verifies one cancelled startup result and waits for both native
pipelines to stop. This uses the real output implementation without a shipping
delay, new injection hook, launched app or physical capture device. It complements
the existing Coordinator FIFO and Close-admission tests; it does not claim an
interactive click inside every native startup subphase.

The ActiveProgramOutputSession and WorkspaceRecordingSettings suites passed all
40 selected tests after the fix. The initial failing regression is recorded in
`/tmp/ldtx-v027-followup-red.log`; the passing run is in
`/tmp/ldtx-v027-followup-output.log`. Swift strict formatting and diff checks passed.
The ordinary unsigned Debug app build also succeeded; its log is
`/tmp/ldtx-v027-followup-build.log`.

The FileProvider sample was reviewed again. A bounded, read-only Foundation
`getRelationship` probe against the local fixture completed in approximately
7 ms. The former iCloud `Untitled 2.ldtxworkspace` candidate no longer exists;
the same probe returned Cocoa error 260 in approximately 4 ms. These observations
do not reproduce the earlier stall or establish its cause: the original sample
does not identify the actual getxattr target, and the missing package is not an
equivalent reproduction. Evidence is in
`/tmp/ldtx-v027-fileprovider-probe-results.json`. The same probe against the
existing parent iCloud Documents directory returned normally in approximately
5 ms (`/tmp/ldtx-v027-fileprovider-parent-probe.json`). No iCloud settings, user packages,
autosave safety checks or FileProvider processes were modified. A current
reproduction and its exact document location/operation would be needed before
claiming a fix for that incident. The user subsequently confirmed that the
ordinary app does not reproduce the stall. The incident therefore remains an
unexplained observation from the isolated test copy, with no confirmed
ordinary-app defect and no speculative persistence workaround applied.

## Native-start Stop and Close UI verification

After commit `116c4d31`, the user requested completion of the remaining Stop/Close
UI checks. The working tree was clean at the start. A separate local app copy,
`/tmp/LDTX-v027-Native-Start-QA.app`, used the existing isolated test Bundle ID
and local Local-A fixture; its copied iCloud declaration was removed. The
production app at PID 93581 was left running and unchanged throughout.

Temporary instrumentation awaited a hold file in the native output pipeline
after successful mixer startup, immediately before activation. The actual
ActiveProgramOutputSession lifecycle and WorkspaceV4RecordingSession state were
both starting. This moves the controlled window inside native startup, beyond
the Coordinator preparation phase tested previously. Waiting was asynchronous,
bounded to 45 seconds, and explicitly released after approximately 11 and 13
seconds; neither run timed out. The local fixture recorded Landscape output
from synthetic content, without a physical capture device or external stream.

The actual UI buttons were operated through accessibility:

- Stop during native startup: Start was disabled and Stop enabled. Clicking Stop
  logged `stop_requested ui=starting native=starting`; the window remained in
  starting until release. Logs then showed start_completed, stop_operation_started
  and stop_completed, in order. UI returned to Start enabled and Stop disabled.
- Close during a separate native startup: clicking the native close button logged
  `close_validation ui=starting native=starting`. The alert required Stop first
  and included Force Quit/data-loss guidance. Dismissing it preserved the same
  Workspace URL and starting UI. Releasing the hold completed recording normally.
  Stop then returned idle; a new Close completed cleanup once and closed the
  Workspace, returning to the Open panel.

The test app subsequently exited normally. Process inspection showed only the
unchanged production app PID 93581. Source backups were restored byte-for-byte
immediately after the instrumented build, before launching the copy. No QA delay
or hook remains in Sources or Tests. Evidence and the temporary build script are
in `/tmp/ldtx-v027-native-start-qa/`, including `events.log`, `native-*.log`,
source backups and the instrumented build log. This closes the remaining native
startup UI verification item for this fixture; it is not an exhaustive test of
every physical device or streaming failure mode. The subsequent ordinary unsigned
Debug rebuild succeeded (`normal-build.log`), restoring the ordinary build
products as well. The only retained repository change is this verification record.
