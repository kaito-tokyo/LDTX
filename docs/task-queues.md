<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Task Queue Design Policy

`LDTXTaskQueue` manages task ordering and queue lifecycles. It does not
implement the concrete work performed by a task. Application code injects that
work through closures and remains responsible for files, media, services, and
UI state.

## Ownership

One Workspace Window owns editing, persistence, and Output orchestration. The
window switches between Edit and Output modes without replacing its
`WorkspaceWindowRuntime`. Entering Output first saves the `.ldtxworkspace` and
locks structural editing; the same runtime retains the persisted document lock
and owns the Output Operation until normal finalization or failure cleanup is
complete.

- **Event task queue:** The Workspace Window runtime owns the event queue. It
  serializes Output state transitions and Session creation or termination, and
  lives for the lifetime of that Workspace Window.
- **Session task queue:** Each Session owns a single-use `SessionTaskQueue`. It
  serializes work that produces or updates data belonging to that Session and
  cannot outlive or be reused by another Session.
- **Resource task queue:** Each independently ordered resource owns a generic
  `ResourceTaskQueue<Task>`. Its `Task` type is that resource's command
  vocabulary, and only its executor mutates the resource state. Orthogonal
  resources use distinct queue instances; a task coordinates them by posting a
  command to an explicitly injected target queue, not through a global router.
- **Workspace resource queue:** A Workspace Window owns one
  `WorkspaceResourceQueue` for delayed preparation of resources shared by the
  whole Workspace. It executes accepted preparation operations serially in FIFO
  order. Workspace and Session startup never wait for this queue; consumers use
  an available fallback while a resource is not ready. Workspace shutdown stops
  accepting operations, drains every accepted operation without interruption,
  then runs registered cleanup operations before completing.

`ResourceTaskQueue` starts commands in FIFO order and does not start the next
command until the current async executor returns. `finishAfterDraining()`
rejects new commands and drains accepted work. `stop()` rejects new commands,
discards commands that have not started, signals the running command through a
`StopToken`, and waits for it to return. A raw `DispatchQueue` may implement a
queue or timer privately, but must not be exposed as a resource ownership API;
timer callbacks post commands instead of mutating resource state directly.

`WorkspaceResourceQueue` is deliberately independent from both
`ResourceTaskQueue` and best-effort background queues. It has no stop operation
or `StopToken`: closing or reloading a Workspace may take time while accepted
resource preparation drains. Cleanup is a terminal queue phase and runs exactly
once after preparation has drained.

Session-independent output control work belongs on the Workspace Window's event
task queue. Session Record Cut request acceptance, sync-sample commit, current
service replacement, old-service finalizer registration, Pause, and Stop all use
that same FIFO queue. Media callbacks may retain samples in an explicit Cut
boundary while the commit is queued, but they cannot replace the current
service themselves. The Session task queue remains responsible for artifacts
such as Screenshots and must release its Session Record lease on every success,
failure, cancellation, and submission-rejection path.
Small operations that must run without a Session may execute directly on the
MainActor when they do not access Session state or Session-owned output.

## Low-frequency notifications are not tasks

`LowFrequencyUpdateRegistry` is an app-owned notification hub, not a task
queue. The application creates one registry and injects it into every Program
runtime and standalone preview. Its best-effort timer invokes short callbacks
roughly once per second without alignment, ordering, or catch-up guarantees.
Subscribers read their own current-time provider and dispatch renderer work to
the renderer queue; they do not perform rendering in the registry callback.

A `LowFrequencyUpdateRegistration` exists only while its component is relevant
to an active preview or output and is cancelled on removal, deactivation, or
shutdown. Recurring notifications must not be implemented with
`EventTaskQueue` or `SessionTaskQueue`, whose one-shot lifecycle and
finalization contracts are different.

## Output failure handling

Output services report failures to the Workspace Window runtime instead of
implementing local recovery. The runtime serializes one failure handler on its event
task queue.
That handler notifies the user immediately, stops the complete output Session,
drains Session work, finalizes its outputs, and returns the Workspace to a
stopped state. A failed recording or streaming sink must not leave the other
sink running as a partial Session.

The failure handler does not retry or restart output automatically. Future
recovery policies may select a different Workspace-level event flow from user
settings, but service implementations must remain unaware of that policy.

## Session completion

A Session task queue owns the completion flow, but not its concrete Finalize
implementation. The Session injects a Finalize task when it creates the queue.
The queue treats that task only as the final unit of work and does not know
whether it writes files, stops a service, or performs another operation.

Calling `finish()` follows one fixed sequence:

1. Atomically stop accepting new tasks.
2. Complete every task accepted before `finish()`.
3. Execute the injected Finalize task exactly once.
4. Notify all finish observers after Finalize completes.
5. Permanently mark the queue as finished.

Submitting a task after finishing begins must fail. A new Session must create a
new queue instead of reopening a finished queue. This makes Finalize the last
operation in the Session and prevents later work from racing with it.

`stop()` is the abnormal-termination path. It rejects new submissions, requests
cooperative cancellation through the queue's `StopToken`, discards pending
work, and does not start the normal Finalize task. An incomplete recording
bundle is intentionally preserved as evidence that the Session did not finish
normally. `stop()` must be selected before Finalize begins; calling it after
Finalize starts is outside the queue contract. This path must not be confused
with the normal `finish()` flow.

## Module boundary

The `LDTXTaskQueue` module may define queue state machines, submission rules,
deduplication policies, stop tokens, one-shot completions, and callback-delivery
contracts. It must not depend on application features or contain concrete
recording, screenshot, vision, storage, or UI implementations.

Application modules decide which work belongs to a Session, construct its task
closures, and inject its Finalize task. This boundary keeps the queue reusable
for future Session types without giving the task-queue module knowledge of any
particular Session.

## Diagnostic event logs

Each Workspace event queue, Workspace resource queue, and Session task queue
receives its own privacy-limited JSONL logger. Tasks decide which fixed event
kinds to append; the queue only passes the logger alongside its `StopToken`.
LDTX keeps the 1,024 most recent Session event-log files for each application
bundle. Retention is enforced when a Session logger closes, while a launch-time
cleanup also bounds event-log files retained from older application versions.
