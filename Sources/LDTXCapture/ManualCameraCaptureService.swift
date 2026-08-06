// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation

/// A manually driven camera source for deterministic media-pipeline tests.
///
/// Unlike ``SyntheticCaptureService``, this source owns no timer. Tests decide
/// exactly when each sample arrives and may choose presentation timestamps that
/// differ from the delivery order.
public final class ManualCameraCaptureService: CameraCaptureStreaming, @unchecked Sendable {
  public struct Request: Equatable, Sendable {
    public var cameraID: String
    public var targetWidth: Int
    public var targetHeight: Int
    public var frameRate: Int
    public var capturesAudio: Bool

    public init(
      cameraID: String,
      targetWidth: Int,
      targetHeight: Int,
      frameRate: Int,
      capturesAudio: Bool
    ) {
      self.cameraID = cameraID
      self.targetWidth = targetWidth
      self.targetHeight = targetHeight
      self.frameRate = frameRate
      self.capturesAudio = capturesAudio
    }
  }

  private let lock = NSLock()
  private var sampleHandler: (@Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void)?
  private var failureHandler: (@Sendable (CaptureSessionRuntimeFailure) -> Void)?
  private var activeRequest: Request?
  private var captureStartCount = 0
  private var currentTimeNanoseconds: UInt64 = 0
  private var nextEventSequence: UInt64 = 0
  private var scheduledEvents: [ScheduledEvent] = []

  public init() {}

  public var request: Request? {
    lock.withLock { activeRequest }
  }

  public var nowNanoseconds: UInt64 {
    lock.withLock { currentTimeNanoseconds }
  }

  public var startCount: Int {
    lock.withLock { captureStartCount }
  }

  public func startCameraCapture(
    cameraID: String,
    audioDeviceID: String? = nil,
    targetWidth: Int,
    targetHeight: Int,
    frameRate: Int,
    capturesAudio: Bool = true,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void = { _ in },
    configurationHandler: (@Sendable (String) -> Void)? = nil,
    handler: @escaping @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    _ = audioDeviceID
    let request = Request(
      cameraID: cameraID,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      frameRate: frameRate,
      capturesAudio: capturesAudio
    )
    lock.withLock {
      captureStartCount += 1
      activeRequest = request
      sampleHandler = handler
      self.failureHandler = failureHandler
    }
    configurationHandler?("Manual capture source started.")
    completionHandler(.success(()))
  }

  public func stop(completionHandler: @escaping @Sendable () -> Void = {}) {
    lock.withLock {
      activeRequest = nil
      sampleHandler = nil
      failureHandler = nil
      scheduledEvents.removeAll(keepingCapacity: true)
    }
    completionHandler()
  }

  /// Delivers a simulated capture failure for deterministic recovery tests.
  public func emitRuntimeFailure(_ failure: CaptureSessionRuntimeFailure) {
    lock.withLock { failureHandler }?(failure)
  }

  /// Delivers a caller-created sample immediately on the caller's executor.
  /// Delivery time and the sample's PTS are deliberately independent.
  @discardableResult
  public func emit(
    _ sampleBuffer: CMSampleBuffer,
    kind: CameraCaptureSampleKind
  ) -> Bool {
    guard let handler = lock.withLock({ sampleHandler }) else {
      return false
    }
    handler(sampleBuffer, kind)
    return true
  }

  /// Creates and delivers one synthetic video sample for the active request.
  @discardableResult
  public func emitVideo(frameIndex: Int) throws -> CMSampleBuffer? {
    guard let request else {
      return nil
    }
    let sampleBuffer = try SyntheticCaptureService.makeVideoSampleBuffer(
      width: request.targetWidth,
      height: request.targetHeight,
      frameIndex: frameIndex,
      frameRate: request.frameRate
    )
    guard emit(sampleBuffer, kind: .video) else {
      return nil
    }
    return sampleBuffer
  }

  /// Schedules a prebuilt sample at a virtual delivery time.
  ///
  /// The sample PTS is not modified. This allows tests to model jitter,
  /// buffering, reordering, and dropped intervals independently of media time.
  public func schedule(
    _ sampleBuffer: CMSampleBuffer,
    kind: CameraCaptureSampleKind,
    atNanoseconds deliveryTimeNanoseconds: UInt64
  ) {
    lock.withLock {
      nextEventSequence &+= 1
      scheduledEvents.append(
        ScheduledEvent(
          deliveryTimeNanoseconds: deliveryTimeNanoseconds,
          sequence: nextEventSequence,
          sampleBuffer: sampleBuffer,
          kind: kind
        ))
      scheduledEvents.sort {
        if $0.deliveryTimeNanoseconds == $1.deliveryTimeNanoseconds {
          return $0.sequence < $1.sequence
        }
        return $0.deliveryTimeNanoseconds < $1.deliveryTimeNanoseconds
      }
    }
  }

  /// Creates a synthetic video frame and schedules it on the virtual timeline.
  @discardableResult
  public func scheduleVideo(
    frameIndex: Int,
    atNanoseconds deliveryTimeNanoseconds: UInt64
  ) throws -> CMSampleBuffer? {
    guard let request else {
      return nil
    }
    let sampleBuffer = try SyntheticCaptureService.makeVideoSampleBuffer(
      width: request.targetWidth,
      height: request.targetHeight,
      frameIndex: frameIndex,
      frameRate: request.frameRate
    )
    schedule(
      sampleBuffer,
      kind: .video,
      atNanoseconds: deliveryTimeNanoseconds
    )
    return sampleBuffer
  }

  /// Advances virtual delivery time and synchronously emits every due event.
  /// Advancing backwards is ignored.
  @discardableResult
  public func advance(toNanoseconds newTimeNanoseconds: UInt64) -> Int {
    let dueEvents: [ScheduledEvent] = lock.withLock {
      guard newTimeNanoseconds >= currentTimeNanoseconds else {
        return []
      }
      currentTimeNanoseconds = newTimeNanoseconds
      let splitIndex =
        scheduledEvents.firstIndex {
          $0.deliveryTimeNanoseconds > newTimeNanoseconds
        } ?? scheduledEvents.endIndex
      let dueEvents = Array(scheduledEvents[..<splitIndex])
      scheduledEvents.removeFirst(splitIndex)
      return dueEvents
    }
    for event in dueEvents {
      _ = emit(event.sampleBuffer, kind: event.kind)
    }
    return dueEvents.count
  }
}

private struct ScheduledEvent {
  var deliveryTimeNanoseconds: UInt64
  var sequence: UInt64
  var sampleBuffer: CMSampleBuffer
  var kind: CameraCaptureSampleKind
}
