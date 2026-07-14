<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Allocation-Free VLM Execution

## Objective

After an explicit preparation phase, executing one Qwen3-VL request must not
create heap storage, grow GPU storage, or grow any cache owned by LDTX, MLX, or
the model runtime. An allocation request after the runtime is frozen is a hard
failure, even if an allocator could satisfy it from a recycling pool.

The fixed execution envelope is:

- one Qwen3-VL model and revision;
- one fixed input pixel format and resolution;
- one fixed processed image size and patch layout;
- one prepared prompt at a time;
- a fixed maximum prompt length;
- a fixed maximum generation length; and
- one in-flight inference per runtime instance.

Changing any item in the envelope leaves the frozen state and requires another
preparation pass.

## Why the current path cannot meet the objective

The current path creates a `CIImage`, a `ChatSession`, an `AsyncStream`, output
`String` values, and a new generation iterator for every request. The Qwen3-VL
processor constructs new MLX arrays for resized and normalized pixels,
patchification, prompt tokens, and masks. Token generation also creates and
grows caches.

MLX recycles released buffers, but recycling is not equivalent to making no
allocation request. Metal command buffers and some system-framework objects are
also created per submission. Apple does not provide a public guarantee that
Core Image, Metal, Swift concurrency, or Objective-C runtime calls will avoid
all internal allocations.

Consequently, literal process-wide zero allocation cannot be guaranteed while
using the current high-level APIs. The runtime must avoid them in its owned hot
path and needs allocation auditing below MLX. System and driver allocations must
be reported separately because public APIs cannot prohibit them.

## Runtime design

### Preparation phase

The preparation phase may allocate. It must:

1. load and evaluate all model weights;
2. tokenize the prompt and create every image placeholder token;
3. calculate the fixed Qwen3-VL target size and `THW` patch layout;
4. allocate all input, normalized-pixel, patch, logits, sampler, and output-token
   storage;
5. allocate fixed-capacity KV caches for the maximum prompt and generation
   lengths;
6. compile and execute every MLX graph shape used by prefill and decoding;
7. prime every Metal pipeline and command path;
8. fill every MLX recycling-pool size class needed by the request; and
9. enter allocator freeze mode.

Prompt editing is permitted only outside the frozen state. Preparation stores
token IDs, not the prompt `String`, in the runtime request template.

### Frozen execution phase

The frozen API must be synchronous and operate on caller-owned or pooled storage:

```swift
func execute(
  pixelBuffer: CVPixelBuffer,
  outputTokenStorage: UnsafeMutableBufferPointer<Int32>
) throws -> AllocationFreeVLMResult
```

It must not use `Task`, `AsyncStream`, `Array` growth, `Dictionary`, `String`
concatenation, `CIImage`, `CIContext`, or per-request object construction.
Generated text is decoded after leaving the frozen section, or into a separate
fixed-capacity UTF-8 buffer with a tokenizer implementation proven not to
allocate.

### Image preprocessing

A dedicated Metal kernel reads the fixed CVPixelBuffer layout and writes
directly into the final Qwen3-VL patch layout. It fuses:

- YCbCr-to-RGB conversion when the input is NV12;
- fixed-size bicubic sampling;
- mean and standard-deviation normalization;
- temporal-patch duplication; and
- spatial patchification.

There are no resized-image or normalized-image intermediates. Input and output
textures/buffers are created during preparation and held by a fixed-size slot.
A busy slot causes backpressure; it never allocates an overflow slot.

### Model execution

`ChatSession` and the public streaming generation API are not used. A dedicated
Qwen3-VL executor owns:

- prepared `LMInput.Text` storage;
- prepared `LMInput.ProcessedImage` metadata;
- fixed-capacity KV cache storage;
- a fixed token-output buffer;
- a deterministic sampler with no dynamically created processor chain; and
- precompiled fixed-shape prefill and one-token decode functions.

The current MLX KV cache and generation iterator must be replaced or modified if
instrumentation shows any capacity growth or allocation request.

## Required dependency changes

Meeting the objective requires controlled forks of `mlx-swift-lm` and likely
`mlx-swift`/MLX core. The forks need:

1. a fixed-capacity KV cache whose backing arrays never change after prepare;
2. an executor that accepts preallocated input and output storage;
3. an MLX allocator audit counter;
4. allocator freeze mode that traps or returns an error on every cache miss or
   backing allocation; and
5. stable hooks exposing buffer-pool hits, misses, active bytes, and cache bytes.

Relying only on `Memory.activeMemory` and `Memory.cacheMemory` is insufficient:
unchanged byte counts do not prove that no allocation request occurred.

## Verification gates

The runtime is not allocation-free until all gates pass for repeated inference:

1. Prepare one runtime for the complete fixed envelope.
2. Reset malloc stack logging or an equivalent allocation counter.
3. Reset MLX allocator request, hit, miss, and backing-allocation counters.
4. Execute at least 10,000 requests without changing input shape or prompt.
5. Assert zero MLX pool misses and zero MLX backing allocations.
6. Assert no growth in active MLX bytes, cached MLX bytes, resident size, or
   VM-region count.
7. Assert no allocations whose stack originates in the LDTX frozen path.
8. Classify any remaining Metal/driver/framework allocation separately and fail
   the literal process-wide requirement if it cannot be eliminated.
9. Run the same gate under Thread Sanitizer-disabled release optimization, since
   diagnostics introduce allocations.

Tests must include the maximum prompt and generation lengths, cancellation by
the caller, repeated identical frames, alternating frame contents, and
backpressure while the only execution slot is busy.

## Implementation order

1. Add allocation instrumentation before changing preprocessing.
2. Replace the current result path with fixed token storage and decode outside
   the measured region.
3. Add fixed-capacity KV caches and a synchronous generation loop.
4. Add the fused CVPixelBuffer-to-patch Metal kernel.
5. Add MLX allocator freeze mode and make any miss fail the request.
6. Remove every remaining allocation stack reported by the 10,000-request gate.
7. Audit unavoidable system/driver allocations and decide whether the literal
   process-wide objective is supportable on the target macOS and GPU.

