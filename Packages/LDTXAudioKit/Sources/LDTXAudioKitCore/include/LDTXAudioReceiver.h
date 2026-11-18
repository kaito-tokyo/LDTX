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
 The receiver lifecycle is Create, AddAvailabilityCallback, Run, Acquire/Get/Release,
 and Destroy. Buffer data and timestamps are receiver-owned borrows protected
 by read leases and generation tokens.
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
 @param priv The optional private context supplied when the callback was registered.
 @param slot The slot containing the published buffer.
 @param token The generation token for the published slot.
 */
typedef void (*LDTXAudioReceiverAvailabilityCallback)(void *__nullable priv, uint32_t slot, uint64_t token);

/*! @function LDTXAudioReceiverCreate
 @abstract Creates a receiver for an audio device.
 @discussion Ownership of a successful result is transferred to the caller.
 @param deviceID The Core Audio device to receive from.
 @result A new receiver, or NULL if creation fails.
 */
LDTXAudioReceiverRef __nullable LDTXAudioReceiverCreate(AudioDeviceID deviceID);

/*! @function LDTXAudioReceiverGetFormat
 @abstract Returns the configured client stream format.
 @param ctx The receiver whose format is requested.
 @result The configured AudioStreamBasicDescription, returned by value.
 */
AudioStreamBasicDescription LDTXAudioReceiverGetFormat(LDTXAudioReceiverRef __nonnull refCon);

/*! @function LDTXAudioReceiverAddAvailabilityCallback
 @abstract Adds a callback for newly available buffers.
 @discussion Callbacks may be added only before Run. The
 callback and private context remain registered until receiver destruction.
 @param ctx The receiver to configure.
 @param callback The callback to invoke when a buffer is published.
 @param priv The optional private context passed to the callback.
 @result true if the callback was added; otherwise false.
 */
bool LDTXAudioReceiverAddAvailabilityCallback(LDTXAudioReceiverRef __nonnull refCon,
                                              LDTXAudioReceiverAvailabilityCallback __nonnull callback,
                                              void *__nullable priv);

/*! @function LDTXAudioReceiverRun
 @abstract Initializes and starts the receiver synchronously.
 @discussion Availability callbacks must be registered first. A Run attempt is
 one-shot; after it fails, Destroy is the only lifecycle operation allowed.
 Returns only after the Audio Unit has started successfully.
 @param refCon The receiver to run.
 @result noErr on success, or the Audio Unit error that prevented startup.
 */
OSStatus LDTXAudioReceiverRun(LDTXAudioReceiverRef __nonnull refCon);

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

/*! @function LDTXAudioReceiverDestroy
 @abstract Destroys a receiver.
 @discussion Stops the Audio Unit and waits for active input callbacks. Returns
 an error if read leases remain; in that case the receiver remains valid and
 stopped so the leases can be released before retrying Destroy. On success the
 receiver is consumed. After success the handle and its borrows must not be used.
 The caller must serialize Destroy with other API calls and must not call it
 from an availability callback.
 @param refCon The receiver owned by the caller.
 @result noErr if destroyed; otherwise an Audio Unit error or
 kAudioUnitErr_CannotDoInCurrentContext if read leases remain.
 */
OSStatus LDTXAudioReceiverDestroy(LDTXAudioReceiverRef __nonnull refCon);

#ifdef __cplusplus
}
#endif
