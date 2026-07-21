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

- **Event task queue:** A Workspace owns its `EventTaskQueue`. It serializes
  control flows such as state transitions and Session creation or termination,
  and lives for the lifetime of the Workspace.
- **Session task queue:** Each Session owns a single-use `SessionTaskQueue`. It
  serializes work that produces or updates data belonging to that Session and
  cannot outlive or be reused by another Session.

Session-independent control work belongs on the Workspace's event task queue.
Small operations that must run without a Session may execute directly on the
MainActor when they do not access Session state or Session-owned output.

## Output failure handling

Output services report failures to the Workspace instead of implementing local
recovery. The Workspace serializes one failure handler on its event task queue.
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
recording, screenshot, vision, automation, storage, or UI implementations.

Application modules decide which work belongs to a Session, construct its task
closures, and inject its Finalize task. This boundary keeps the queue reusable
for future Session types without giving the task-queue module knowledge of any
particular Session.
