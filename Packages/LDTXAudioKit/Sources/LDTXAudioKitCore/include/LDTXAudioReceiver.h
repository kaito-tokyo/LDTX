// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <stdbool.h>
#include <stdint.h>

#include <AudioToolbox/AudioToolbox.h>

/*! @header
 @abstract Receives Float32 non-interleaved audio from a HAL output unit.
 @discussion
 The receiver lifecycle is Create, AddAvailabilityCallback, Start,
 Acquire/Get/Release, Stop, and Destroy. Buffer data and timestamps are
 receiver-owned borrows protected by read leases and generation tokens.
 */

#ifdef __cplusplus
extern "C" {
#endif

typedef void *LDTXAudioReceiverRef;

/*! @callback LDTXAudioReceiverAvailabilityCallback
 @abstract Reports that a newly rendered buffer is available.
 @discussion
 The slot and token identify one published buffer generation. The callback must
 acquire a read lease before accessing the buffer and release it exactly once.
 @param priv The private context supplied when the callback was registered.
 @param slot The slot containing the published buffer.
 @param token The generation token for the published slot.
 */
typedef void (*LDTXAudioReceiverAvailabilityCallback)(void *__nonnull priv, uint32_t slot, uint64_t token);

/*! @callback LDTXAudioReceiverStopCallback
 @abstract Reports that an asynchronous stop has completed.
 @discussion
 The callback receives no receiver pointer. An owner may destroy the receiver
 from this callback. It normally runs on the control queue; an already-stopped
 receiver invokes it immediately on the calling thread.
 @param priv The optional private context supplied to LDTXAudioReceiverStop.
 */
typedef void (*LDTXAudioReceiverStopCallback)(void *__nullable priv);

/*! @function LDTXAudioReceiverCreate
 @abstract Creates a stopped receiver for an audio device.
 @discussion Ownership of a successful result is transferred to the caller.
 @param deviceID The Core Audio device to receive from.
 @result A new receiver, or NULL if creation fails.
 */
LDTXAudioReceiverRef __nullable LDTXAudioReceiverCreate(AudioDeviceID deviceID);

/*! @function LDTXAudioReceiverDestroy
 @abstract Destroys a receiver.
 @discussion Completes pending stop work and waits for active writers and read
 leases before releasing Audio Unit resources.
 @param ctx The receiver owned by the caller.
 */
void LDTXAudioReceiverDestroy(LDTXAudioReceiverRef __nonnull refCon);

/*! @function LDTXAudioReceiverGetFormat
 @abstract Returns the configured client stream format.
 @param ctx The receiver whose format is requested.
 @result The configured AudioStreamBasicDescription, returned by value.
 */
AudioStreamBasicDescription LDTXAudioReceiverGetFormat(LDTXAudioReceiverRef __nonnull refCon);

/*! @function LDTXAudioReceiverAddAvailabilityCallback
 @abstract Adds a callback for newly available buffers.
 @discussion Callbacks may be added only while the receiver is stopped. The
 callback and private context remain registered until receiver destruction.
 @param ctx The receiver to configure.
 @param callback The callback to invoke when a buffer is published.
 @param priv The non-NULL private context passed to the callback.
 @result true if the callback was added; otherwise false.
 */
bool LDTXAudioReceiverAddAvailabilityCallback(LDTXAudioReceiverRef __nonnull refCon,
                                              LDTXAudioReceiverAvailabilityCallback __nonnull callback,
                                              void *__nullable priv);

/*! @function LDTXAudioReceiverStart
 @abstract Starts the receiver synchronously.
 @discussion Returns only after the Audio Unit has started successfully.
 @param ctx The stopped receiver to start.
 @result true if the receiver is running; otherwise false.
 */
bool LDTXAudioReceiverStart(LDTXAudioReceiverRef __nonnull refCon);

/*! @function LDTXAudioReceiverStop
 @abstract Requests an asynchronous stop.
 @discussion Stops and uninitializes the Audio Unit, rejects new callback
 writes, and waits for active writers and read leases to drain. A non-NULL
 callback is invoked exactly once after completion. It normally runs on the
 control queue; an already-stopped receiver invokes it on the calling thread.
 A non-NULL priv is ignored when callback is NULL. Repeated stop requests do
 not repeat Audio Unit shutdown.
 @param ctx The receiver to stop.
 @param callback The optional completion callback.
 @param priv The optional private context passed to callback.
 */
void LDTXAudioReceiverStop(LDTXAudioReceiverRef __nonnull refCon, LDTXAudioReceiverStopCallback __nullable callback,
                           void *__nullable priv);

/*! @function LDTXAudioReceiverAcquireBuffer
 @abstract Acquires one read lease for a published buffer.
 @discussion A failed acquisition does not change the lease count. Every
 successful acquisition must be paired with exactly one release. The token
 identifies the slot generation and rejects stale access.
 @param ctx The receiver that owns the slot.
 @param slot The published buffer slot.
 @param token The generation token supplied by the availability callback.
 @result true if a read lease was acquired; otherwise false.
 */
bool LDTXAudioReceiverAcquireBuffer(LDTXAudioReceiverRef __nonnull refCon, uint32_t slot, uint64_t token);

/*! @function LDTXAudioReceiverGetBufferData
 @abstract Returns the receiver-owned buffer for an active read lease.
 @discussion The returned pointer is valid only while the matching read lease
 is held and must not be accessed after release. Returns NULL if no matching
 active lease exists.
 @param ctx The receiver that owns the slot.
 @param slot The leased buffer slot.
 @param token The generation token used to acquire the lease.
 @result A const AudioBufferList borrow, or NULL if the lease is invalid.
 */
const AudioBufferList *__nullable LDTXAudioReceiverGetBufferData(LDTXAudioReceiverRef __nonnull refCon, uint32_t slot,
                                                                 uint64_t token);

/*! @function LDTXAudioReceiverGetBufferTimeStamp
 @abstract Returns the receiver-owned timestamp for an active read lease.
 @discussion The returned pointer is valid only while the matching read lease
 is held and must not be accessed after release. Returns NULL if no matching
 active lease exists.
 @param ctx The receiver that owns the slot.
 @param slot The leased buffer slot.
 @param token The generation token used to acquire the lease.
 @result A const AudioTimeStamp borrow, or NULL if the lease is invalid.
 */
const AudioTimeStamp *__nullable LDTXAudioReceiverGetBufferTimeStamp(LDTXAudioReceiverRef __nonnull refCon,
                                                                     uint32_t slot, uint64_t token);

/*! @function LDTXAudioReceiverReleaseBuffer
 @abstract Releases one active read lease.
 @discussion Every successful acquisition must be released exactly once. The
 buffer and timestamp borrows must not be accessed after this call.
 @param ctx The receiver that owns the slot.
 @param slot The leased buffer slot.
 @param token The generation token used to acquire the lease.
 */
void LDTXAudioReceiverReleaseBuffer(LDTXAudioReceiverRef __nonnull refCon, uint32_t slot, uint64_t token);

#ifdef __cplusplus
}
#endif
