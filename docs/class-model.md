<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Class Model

This document sketches the top-level lifecycle structure of LDTX.

```mermaid
flowchart TD
    App["LDTX App"]

    App --> ActiveProgram["Active Program"]
    App --> DefinedPrograms["All defined Programs"]
    App --> CaptureSessions["[AVCaptureSession]"]
    App --> MemoryPools["Memory pools"]
```

## Active Program

Active Program is the Main stream screen. It can be shown on the Preview screen, recorded, or streamed.

All defined Programs only exist as available definitions. A Program gains runtime management responsibility when it is promoted to Active Program.

Active Program is responsible for the areas and resources needed by the active Program. For now, Active Program owns all runtime management responsibility except `[AVCaptureSession]`.

Capture services, including the audio input services owned by
`ProgramAudioMonitor`, live outside an active output session. An
`ActiveProgramOutputSession` is a single-use output graph: starting a new
recording part or restarting output stops and finalizes the old graph, then
constructs a new graph with new writers, encoders, timeline normalization, and
input-sample subscriptions. It must not reopen an input device or rotate a
writer in place.

Continuity behavior belongs at an output boundary. For example, an output
service may hold its last accepted video frame while upstream output is being
reconstructed. Capture and active-program stages do not retain output-session
state to hide such a gap.

For YouTube output, `YouTubeOutputWorkspaceService` is owned by the
`WorkspaceWindowRuntime`'s Output Operation rather than by
`ActiveProgramOutputSession`. It owns an
ephemeral, in-memory DASH checkpoint for its endpoint. When XPC is interrupted or the
ServiceProcess requests a reset, the Output Operation service discards its media
batcher and its one-to-one `YouTubeOutputServiceProcess` session, then creates a
fresh pair from that checkpoint. Only DASH continuity state, including the next
segment number and media time, crosses this boundary; encoder, request, queue,
and connection state do not.

Each XPC connection owns one isolated `YouTubeOutputServiceProcess` session.
Bootstrap supplies the Output Operation's in-memory checkpoint and always creates
a fresh media processor. The service publishes checkpoint updates back to the
Output Operation over the client XPC interface. Neither side writes this state to disk.
The Workspace Window failure handler aborts a failed pair immediately and makes up to
three replacement attempts at a fixed four-second interval. A fourth failure is
reported immediately so recovery can return to explicit user intervention.
Explicit stop, pause, and terminal failure finish the current pair.

Memory ownership still ends at Memory pools. Active Program does not need to strictly own the lifetime of individual memory allocations.

## Memory pools

Memory pools have the same lifecycle as the app window. They hold `CVPixelBufferPool` instances and vend `CVPixelBuffer` values from those pools.

Different Programs and components can require different pixel-buffer settings.
Memory pools receive requests from Programs or components, prepare matching `CVPixelBufferPool` instances, and provide buffers when needed.

Individual `CVPixelBuffer` lifetime is handled by Core Video reference counting, so LDTX does not need its own buffer reference counting for now.

## Concurrency and callback policy

Swift Package modules provide synchronous APIs by default. They do not choose
an executor or introduce parallelism on behalf of the app unless an underlying
framework requires asynchronous delivery.

Use APIs in this order of preference:

1. synchronous methods;
2. delegate or protocol callbacks for streams of external events;
3. completion-handler methods for operations that finish later; and
4. `async` APIs only when the dependency has no synchronous, delegate, or
   completion-handler equivalent.

When a framework provides equivalent `async` and completion-handler variants,
Package code must use the completion-handler variant. Package modules do not
publish convenience `async` wrappers. The app and UI layers may wrap a
completion-handler API in `async`/`await` when that makes an interaction flow
clearer.

Media data follows an additional ownership rule. A `CMSampleBuffer`,
`CVPixelBuffer`, `CVMetalTexture`, or other reference to shared media storage
must not cross a concurrency boundary merely by being captured in an escaping
closure, stored in a continuation, or hidden in an `@unchecked Sendable`
wrapper. A media stage must instead do one of the following:

- borrow the buffer synchronously on the stage's documented queue;
- retain it in explicit in-flight state until the downstream consumer reports
  completion; or
- repack it into storage whose ownership belongs to the downstream stage.

Completion handlers communicate completion, errors, identifiers, and immutable
summary values. They should not transport media buffers. Each completion
handler must be invoked exactly once, and its callback queue must be part of the
API contract.
