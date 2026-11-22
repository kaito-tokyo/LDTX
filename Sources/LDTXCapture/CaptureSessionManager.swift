// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import LDTXCorelibs
import OSLog

public struct CaptureSessionVideoRequest: Equatable, Sendable {
  public var sourceKey: String
  public var deviceID: String
  public var targetWidth: Int
  public var targetHeight: Int
  public var frameRate: Int

  public init(
    sourceKey: String,
    deviceID: String,
    targetWidth: Int,
    targetHeight: Int,
    frameRate: Int
  ) {
    self.sourceKey = sourceKey
    self.deviceID = deviceID
    self.targetWidth = targetWidth
    self.targetHeight = targetHeight
    self.frameRate = frameRate
  }
}

public struct CaptureSessionRequest: Equatable, Sendable {
  public var videoInputs: [CaptureSessionVideoRequest]

  public init(videoInputs: [CaptureSessionVideoRequest] = []) {
    self.videoInputs = videoInputs
  }
}

public struct CapturedSample {
  public var sourceKey: String
  public var deviceID: String
  public var kind: CameraCaptureSampleKind
  public var sampleBuffer: CMSampleBuffer

  public init(
    sourceKey: String,
    deviceID: String,
    kind: CameraCaptureSampleKind,
    sampleBuffer: CMSampleBuffer
  ) {
    self.sourceKey = sourceKey
    self.deviceID = deviceID
    self.kind = kind
    self.sampleBuffer = sampleBuffer
  }
}

public enum CaptureSessionRuntimeFailure: Error, Sendable, Equatable {
  case audioFormatChanged(
    deviceID: String,
    previous: AudioStreamBasicDescription,
    current: AudioStreamBasicDescription
  )
  case deviceDisconnected(deviceID: String)
  case sessionRuntimeError(code: Int)
  case sessionInterrupted(reason: Int)

  public static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (
      .audioFormatChanged(let lhsID, let lhsPrevious, let lhsCurrent),
      .audioFormatChanged(let rhsID, let rhsPrevious, let rhsCurrent)
    ):
      lhsID == rhsID && lhsPrevious.hasSameFormat(as: rhsPrevious)
        && lhsCurrent.hasSameFormat(as: rhsCurrent)
    case (.deviceDisconnected(let lhsID), .deviceDisconnected(let rhsID)):
      lhsID == rhsID
    case (.sessionRuntimeError(let lhsCode), .sessionRuntimeError(let rhsCode)):
      lhsCode == rhsCode
    case (.sessionInterrupted(let lhsReason), .sessionInterrupted(let rhsReason)):
      lhsReason == rhsReason
    default:
      false
    }
  }
}

extension AudioStreamBasicDescription {
  fileprivate func hasSameFormat(as other: Self) -> Bool {
    mSampleRate == other.mSampleRate
      && mFormatID == other.mFormatID
      && mFormatFlags == other.mFormatFlags
      && mBytesPerPacket == other.mBytesPerPacket
      && mFramesPerPacket == other.mFramesPerPacket
      && mBytesPerFrame == other.mBytesPerFrame
      && mChannelsPerFrame == other.mChannelsPerFrame
      && mBitsPerChannel == other.mBitsPerChannel
  }
}

public enum CaptureSessionManagerError: Error, Equatable, LocalizedError {
  case cameraAccessDenied
  case videoDeviceNotAllowed(String)
  case videoDeviceNotFound(String)
  case cannotAddInput(String)
  case cannotAddOutput(String)
  case cannotAddConnection(String)
  case missingInputPort(String)
  case unsupportedVideoPixelFormat(String)
  case invalidRequest

  public var errorDescription: String? {
    switch self {
    case .cameraAccessDenied:
      "Camera access was denied."
    case .videoDeviceNotAllowed(let id):
      "The video device is not in the allowed capture device list: \(id)."
    case .videoDeviceNotFound(let id):
      "The video device could not be found: \(id)."
    case .cannotAddInput(let id):
      "The capture input could not be added: \(id)."
    case .cannotAddOutput(let key):
      "The capture output could not be added: \(key)."
    case .cannotAddConnection(let key):
      "The capture connection could not be added: \(key)."
    case .missingInputPort(let key):
      "The capture input port could not be found: \(key)."
    case .unsupportedVideoPixelFormat(let format):
      "The capture video pixel format is not supported: \(format)."
    case .invalidRequest:
      "The capture session request is empty."
    }
  }
}

// @unchecked Sendable: `session`, `notificationObservers`, `activeDeviceIDs` and
// `activeVideoRequests` are used only on `sessionQueue`; `outputsByID`, `sampleHandler` and
// `failureHandler` only on `sampleQueue`, the delegate queue, with off-queue access going through
// `sampleQueue.sync`;
// `startupCompletionHandler` only inside `startupLock`.
public final class CaptureSessionManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  public typealias SampleHandler = @Sendable (CapturedSample) -> Void
  public typealias FailureHandler = @Sendable (CaptureSessionRuntimeFailure) -> Void

  private static let logger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "CaptureSessionManager"
  )
  private static let signpostLog = OSLog(
    subsystem: "tokyo.kaito.ldtx",
    category: "PointsOfInterest"
  )

  private let allowedVideoDeviceIDs: Set<String>?
  private let sessionQueue = DispatchQueue(label: "tokyo.kaito.ldtx.CaptureSessionManager.session")
  private let sampleQueue = DispatchQueue(label: "tokyo.kaito.ldtx.CaptureSessionManager.samples")
  private let startupLock = NSLock()

  private var session: AVCaptureSession?
  private var outputsByID: [ObjectIdentifier: ManagedOutput] = [:]
  private var sampleHandler: SampleHandler?
  private var failureHandler: FailureHandler?
  private var startupCompletionHandler: (@Sendable (Result<Void, any Error>) -> Void)?
  private var notificationObservers: [NSObjectProtocol] = []
  private var activeDeviceIDs: Set<String> = []
  private var activeVideoRequests: [CaptureSessionVideoRequest] = []

  public init(allowedVideoDeviceIDs: Set<String>? = nil) {
    self.allowedVideoDeviceIDs = allowedVideoDeviceIDs
    super.init()
  }

  public func availableCameras() -> [CameraCaptureSource] {
    Self.allVideoDevices()
      .filter { allowedVideoDeviceIDs?.contains($0.uniqueID) ?? true }
      .map(Self.cameraSource(from:))
  }

  public func start(
    request: CaptureSessionRequest,
    handler: @escaping SampleHandler,
    failureHandler: @escaping FailureHandler = { _ in },
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard !request.videoInputs.isEmpty else {
      completionHandler(.failure(CaptureSessionManagerError.invalidRequest))
      return
    }
    requestRequiredAccess(for: request) { [weak self] result in
      guard let self else {
        completionHandler(.success(()))
        return
      }
      switch result {
      case .success:
        self.startOnSessionQueue(
          request: request,
          handler: handler,
          failureHandler: failureHandler,
          completionHandler: completionHandler
        )
      case .failure(let error):
        completionHandler(.failure(error))
      }
    }
  }

  public func stop(completionHandler: @escaping @Sendable () -> Void = {}) {
    sessionQueue.async { [weak self] in
      guard let self else {
        completionHandler()
        return
      }
      self.stopOnSessionQueue()
      completionHandler()
    }
  }

  public func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    let outputID = ObjectIdentifier(output)
    guard let managedOutput = outputsByID[outputID] else {
      return
    }
    let callbackStart = Self.hostTimeNanoseconds()
    sampleHandler?(
      CapturedSample(
        sourceKey: managedOutput.sourceKey,
        deviceID: managedOutput.deviceID,
        kind: managedOutput.kind,
        sampleBuffer: sampleBuffer
      ))
    let callbackEnd = Self.hostTimeNanoseconds()
    let report = outputsByID[outputID]?.deliveryStats.recordDelivered(
      presentationNanoseconds: Self.nanoseconds(
        of: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
      callbackStartNanoseconds: callbackStart,
      callbackEndNanoseconds: callbackEnd
    )
    if let report {
      Self.logDeliveryReport(report, for: managedOutput)
    }
  }

  public func captureOutput(
    _ output: AVCaptureOutput,
    didDrop sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    let outputID = ObjectIdentifier(output)
    guard let managedOutput = outputsByID[outputID] else {
      return
    }
    let report = outputsByID[outputID]?.deliveryStats.recordDropped(
      reason: Self.dropReason(of: sampleBuffer),
      nowNanoseconds: Self.hostTimeNanoseconds()
    )
    if let report {
      Self.logDeliveryReport(report, for: managedOutput)
    }
  }

  private func configureAndStart(
    request: CaptureSessionRequest,
    handler: @escaping SampleHandler,
    failureHandler: @escaping FailureHandler
  ) throws {
    let signpostID = OSSignpostID(log: Self.signpostLog)
    os_signpost(
      .begin, log: Self.signpostLog, name: "Capture Session Start", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Self.signpostLog, name: "Capture Session Start", signpostID: signpostID)
    }

    stopOnSessionQueue()
    prepareSampleDeliveryState(failureHandler: failureHandler)

    let session = AVCaptureSession()
    session.beginConfiguration()
    do {
      try configureVideoInputs(request.videoInputs, in: session)
      if session.canSetSessionPreset(.hd1920x1080) {
        session.sessionPreset = .hd1920x1080
      }
    } catch {
      session.commitConfiguration()
      disableSampleBufferDelegates(for: session)
      clearSampleDeliveryState()
      throw error
    }
    session.commitConfiguration()
    self.session = session
    observeRuntimeFailures(for: session, deviceIDs: Set(request.videoInputs.map(\.deviceID)))
    activeVideoRequests = request.videoInputs
    session.startRunning()
    Self.applyRequestedFrameRates(request.videoInputs)
    sampleQueue.sync { self.sampleHandler = handler }
    Self.logger.notice(
      "Capture session started: videoInputs=\(request.videoInputs.count, privacy: .public), videoDevices=\(Self.describeVideoInputs(request.videoInputs), privacy: .private(mask: .hash)), isRunning=\(session.isRunning, privacy: .public)"
    )
  }

  private func configureVideoInputs(
    _ requests: [CaptureSessionVideoRequest],
    in session: AVCaptureSession
  ) throws {
    for (inputIndex, request) in requests.enumerated() {
      if let allowedVideoDeviceIDs, !allowedVideoDeviceIDs.contains(request.deviceID) {
        throw CaptureSessionManagerError.videoDeviceNotAllowed(request.deviceID)
      }
      guard let device = Self.allVideoDevices().first(where: { $0.uniqueID == request.deviceID })
      else {
        throw CaptureSessionManagerError.videoDeviceNotFound(request.deviceID)
      }
      let input = try Self.makeDeviceInput(for: device)
      guard session.canAddInput(input) else {
        throw CaptureSessionManagerError.cannotAddInput(request.deviceID)
      }
      session.addInputWithNoConnections(input)

      let output = AVCaptureVideoDataOutput()
      output.alwaysDiscardsLateVideoFrames = true
      guard
        let pixelFormat = Self.preferredVideoPixelFormat(
          from: output.availableVideoPixelFormatTypes)
      else {
        throw CaptureSessionManagerError.unsupportedVideoPixelFormat("420v, 420f, BGRA")
      }
      output.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
      ]
      guard session.canAddOutput(output) else {
        throw CaptureSessionManagerError.cannotAddOutput(request.sourceKey)
      }
      session.addOutputWithNoConnections(output)
      output.setSampleBufferDelegate(self, queue: sampleQueue)
      try connect(
        input: input,
        mediaType: .video,
        output: output,
        inputIndex: inputIndex,
        sourceKey: request.sourceKey,
        deviceID: request.deviceID,
        kind: .video,
        in: session
      )
    }
  }

  private func connect(
    input: AVCaptureDeviceInput,
    mediaType: AVMediaType,
    output: AVCaptureOutput,
    inputIndex: Int,
    sourceKey: String,
    deviceID: String,
    kind: CameraCaptureSampleKind,
    in session: AVCaptureSession
  ) throws {
    guard let port = input.ports.first(where: { $0.mediaType == mediaType }) else {
      throw CaptureSessionManagerError.missingInputPort(sourceKey)
    }
    let connection = AVCaptureConnection(inputPorts: [port], output: output)
    guard session.canAddConnection(connection) else {
      throw CaptureSessionManagerError.cannotAddConnection(sourceKey)
    }
    session.addConnection(connection)
    sampleQueue.sync {
      outputsByID[ObjectIdentifier(output)] = ManagedOutput(
        inputIndex: inputIndex,
        sourceKey: sourceKey,
        deviceID: deviceID,
        kind: kind
      )
    }
  }

  private func stopOnSessionQueue() {
    if let session {
      let outputs = sampleQueue.sync { Array(self.outputsByID.values) }
      let videoOutputCount = outputs.count
      Self.logger.notice(
        "Stopping capture session: videoOutputs=\(videoOutputCount, privacy: .public), devices=\(outputs.map(\.deviceID).sorted().joined(separator: ","), privacy: .private(mask: .hash)), wasRunning=\(session.isRunning, privacy: .public)"
      )
      disableSampleBufferDelegates(for: session)
    }
    session?.stopRunning()
    removeRuntimeFailureObservers()
    clearSampleDeliveryState()
    resumeStartup(throwing: CancellationError())
    session = nil
    activeVideoRequests = []
  }

  private func observeRuntimeFailures(for session: AVCaptureSession, deviceIDs: Set<String>) {
    removeRuntimeFailureObservers()
    activeDeviceIDs = deviceIDs
    let center = NotificationCenter.default
    notificationObservers = [
      center.addObserver(
        forName: AVCaptureSession.runtimeErrorNotification,
        object: session,
        queue: nil
      ) { [weak self] notification in
        guard let self else { return }
        let code = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? -1
        sessionQueue.async { [weak self] in
          guard let self else { return }
          switch CaptureSessionRuntimeFailurePolicy.action(
            errorCode: code,
            observedSessionIsCurrent: self.session === session
          ) {
          case .discard:
            return
          case .restart:
            guard !session.isRunning else { return }
            Self.logger.notice(
              "Capture media services were reset; restarting the current session"
            )
            session.startRunning()
            Self.applyRequestedFrameRates(self.activeVideoRequests)
          case .report:
            self.reportRuntimeFailure(.sessionRuntimeError(code: code))
          }
        }
      },
      center.addObserver(
        forName: AVCaptureDevice.wasDisconnectedNotification,
        object: nil,
        queue: nil
      ) { [weak self] notification in
        guard let device = notification.object as? AVCaptureDevice else { return }
        guard let self else { return }
        sessionQueue.async { [weak self] in
          guard self?.activeDeviceIDs.contains(device.uniqueID) == true else { return }
          self?.reportRuntimeFailure(.deviceDisconnected(deviceID: device.uniqueID))
        }
      },
      center.addObserver(
        forName: AVCaptureSession.wasInterruptedNotification,
        object: session,
        queue: nil
      ) { _ in
        Self.logger.notice("Capture session was interrupted; waiting for interruption end")
      },
      center.addObserver(
        forName: AVCaptureSession.interruptionEndedNotification,
        object: session,
        queue: nil
      ) { [weak self] _ in
        guard let self else { return }
        sessionQueue.async { [weak self] in
          guard let self, self.session === session, !session.isRunning else { return }
          Self.logger.notice("Capture session interruption ended; resuming capture")
          session.startRunning()
          Self.applyRequestedFrameRates(self.activeVideoRequests)
        }
      },
    ]
  }

  private func removeRuntimeFailureObservers() {
    let center = NotificationCenter.default
    notificationObservers.forEach(center.removeObserver)
    notificationObservers = []
    activeDeviceIDs = []
  }

  private func reportRuntimeFailure(_ failure: CaptureSessionRuntimeFailure) {
    let handler = sampleQueue.sync { failureHandler }
    handler?(failure)
  }

  private func prepareSampleDeliveryState(
    failureHandler: @escaping FailureHandler
  ) {
    sampleQueue.sync {
      self.failureHandler = failureHandler
    }
  }

  private func clearSampleDeliveryState() {
    sampleQueue.sync {
      outputsByID.removeAll(keepingCapacity: true)
      sampleHandler = nil
      failureHandler = nil
    }
  }

  private func disableSampleBufferDelegates(for session: AVCaptureSession) {
    for output in session.outputs {
      if let videoOutput = output as? AVCaptureVideoDataOutput {
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
      }
    }
  }

  private func startOnSessionQueue(
    request: CaptureSessionRequest,
    handler: @escaping SampleHandler,
    failureHandler: @escaping FailureHandler,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self else {
        completionHandler(.success(()))
        return
      }
      do {
        try self.configureAndStart(
          request: request,
          handler: handler,
          failureHandler: failureHandler
        )
        self.startupLock.withLock {
          self.startupCompletionHandler = completionHandler
        }
        self.resumeStartup()
      } catch {
        completionHandler(.failure(error))
      }
    }
  }

  private func resumeStartup(throwing error: (any Error)? = nil) {
    let completionHandler = startupLock.withLock {
      () -> (@Sendable (Result<Void, any Error>) -> Void)? in
      let completionHandler = startupCompletionHandler
      startupCompletionHandler = nil
      return completionHandler
    }
    if let error {
      completionHandler?(.failure(error))
    } else {
      completionHandler?(.success(()))
    }
  }

  private func requestAccess(
    for mediaType: AVMediaType,
    completionHandler: @escaping @Sendable (Bool) -> Void
  ) {
    switch AVCaptureDevice.authorizationStatus(for: mediaType) {
    case .authorized:
      completionHandler(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: mediaType, completionHandler: completionHandler)
    case .denied, .restricted:
      completionHandler(false)
    @unknown default:
      completionHandler(false)
    }
  }

  private func requestRequiredAccess(
    for request: CaptureSessionRequest,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    requestAccess(for: .video) { granted in
      completionHandler(
        granted ? .success(()) : .failure(CaptureSessionManagerError.cameraAccessDenied))
    }
  }

  static func preferredVideoPixelFormat(from available: [OSType]) -> OSType? {
    [
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA,
    ]
    .first(where: { available.contains($0) })
  }

  private static func allVideoDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.external, .builtInWideAngleCamera],
      mediaType: .video,
      position: .unspecified
    ).devices
  }

  private static func describeVideoInputs(_ requests: [CaptureSessionVideoRequest]) -> String {
    if requests.isEmpty {
      return "none"
    }
    return requests.map {
      "\($0.deviceID)@\($0.targetWidth)x\($0.targetHeight)/\($0.frameRate)"
    }.joined(separator: ",")
  }

  private static func cameraSource(from device: AVCaptureDevice) -> CameraCaptureSource {
    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    return CameraCaptureSource(
      id: device.uniqueID,
      name: device.localizedName,
      deviceType: device.deviceType.rawValue,
      modelID: device.modelID,
      width: Int(dimensions.width),
      height: Int(dimensions.height),
      isExternal: device.deviceType == .external,
      formatSummary: activeVideoConfigurationSummary(for: device)
    )
  }

  private static func makeDeviceInput(for device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
    try AVCaptureDeviceConfigurationGate.withLock {
      try AVCaptureDeviceInput(device: device)
    }
  }

  private static func activeVideoConfigurationSummary(for device: AVCaptureDevice) -> String {
    let activeFormat = device.activeFormat
    let activeDimensions = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription)
    let activePixelFormat = CMFormatDescriptionGetMediaSubType(activeFormat.formatDescription)
    let activeRanges = activeFormat.videoSupportedFrameRateRanges
      .map { range in
        "\(String(format: "%.3f", range.minFrameRate))-\(String(format: "%.3f", range.maxFrameRate))fps"
      }
      .joined(separator: ",")
    return
      "\(Int(activeDimensions.width))x\(Int(activeDimensions.height)), pixelFormat=\(fourCC(activePixelFormat)), frameRates=[\(activeRanges)], activeMaxFPS=\(frameRateDescription(for: device.activeVideoMinFrameDuration)), activeMinFPS=\(frameRateDescription(for: device.activeVideoMaxFrameDuration))"
  }

  private static func frameRateDescription(for duration: CMTime) -> String {
    let seconds = duration.seconds
    guard seconds.isFinite, seconds > 0 else { return "invalid" }
    return String(format: "%.3f", 1 / seconds)
  }

  private static func fourCC(_ value: FourCharCode) -> String {
    let scalarValues = [
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ]
    let scalars = scalarValues.map { byte -> UnicodeScalar in
      if byte >= 32 && byte <= 126, let scalar = UnicodeScalar(Int(byte)) {
        return scalar
      }
      return "."
    }
    return String(String.UnicodeScalarView(scalars))
  }

  private struct ManagedOutput {
    var inputIndex: Int
    var sourceKey: String
    var deviceID: String
    var kind: CameraCaptureSampleKind
    var deliveryStats = CaptureFrameDeliveryStats()
  }

  private static func hostTimeNanoseconds() -> UInt64 {
    UInt64(clamping: nanoseconds(of: CMClockGetTime(CMClockGetHostTimeClock())) ?? 0)
  }

  private static func nanoseconds(of time: CMTime) -> Int64? {
    guard time.isValid, time.isNumeric else { return nil }
    return CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero)
      .value
  }

  private static func dropReason(of sampleBuffer: CMSampleBuffer) -> CaptureFrameDropReason {
    let reason =
      CMGetAttachment(
        sampleBuffer,
        key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
        attachmentModeOut: nil
      ) as? String
    if reason == kCMSampleBufferDroppedFrameReason_FrameWasLate as String {
      return .frameWasLate
    }
    if reason == kCMSampleBufferDroppedFrameReason_OutOfBuffers as String {
      return .outOfBuffers
    }
    if reason == kCMSampleBufferDroppedFrameReason_Discontinuity as String {
      return .discontinuity
    }
    return .other
  }

  private static func logDeliveryReport(
    _ report: CaptureFrameDeliveryReport,
    for output: ManagedOutput
  ) {
    logger.notice(
      "Capture frame delivery input=\(output.inputIndex, privacy: .public) device=\(output.deviceID, privacy: .private(mask: .hash)) windowMs=\(milliseconds(report.windowNanoseconds), privacy: .public) delivered=\(report.deliveredCount, privacy: .public) dropped=\(report.droppedCount, privacy: .public) droppedLate=\(report.droppedLateCount, privacy: .public) droppedOutOfBuffers=\(report.droppedOutOfBuffersCount, privacy: .public) droppedDiscontinuity=\(report.droppedDiscontinuityCount, privacy: .public) droppedOther=\(report.droppedOtherCount, privacy: .public) intervalMeanMs=\(milliseconds(report.meanIntervalNanoseconds), privacy: .public) intervalMinMs=\(milliseconds(report.minIntervalNanoseconds), privacy: .public) intervalMaxMs=\(milliseconds(report.maxIntervalNanoseconds), privacy: .public) longIntervals=\(report.longIntervalCount, privacy: .public) maxLatencyMs=\(milliseconds(report.maxDeliveryLatencyNanoseconds), privacy: .public) maxHandlerMs=\(milliseconds(report.maxHandlerNanoseconds), privacy: .public)"
    )
  }

  private static func milliseconds(_ nanoseconds: UInt64) -> String {
    String(format: "%.3f", Double(nanoseconds) / 1_000_000)
  }

  /// Applies each request's frame rate to its device after the session preset has chosen
  /// the active format, then logs the resulting configuration.
  ///
  /// The `.hd1920x1080` preset selects the format but leaves the frame duration at the device
  /// default, which can be lower than requested. Applying it again after every
  /// `startRunning()` keeps the rate when the session restarts.
  private static func applyRequestedFrameRates(_ requests: [CaptureSessionVideoRequest]) {
    let devices = allVideoDevices()
    for (inputIndex, request) in requests.enumerated() {
      guard let device = devices.first(where: { $0.uniqueID == request.deviceID }) else {
        continue
      }
      applyRequestedFrameRate(request.frameRate, to: device, inputIndex: inputIndex)
      logger.notice(
        "Capture video input active configuration input=\(inputIndex, privacy: .public) device=\(request.deviceID, privacy: .private(mask: .hash)) requestedFPS=\(request.frameRate, privacy: .public) active=\(activeVideoConfigurationSummary(for: device), privacy: .public)"
      )
    }
  }

  private static func applyRequestedFrameRate(
    _ requestedFrameRate: Int,
    to device: AVCaptureDevice,
    inputIndex: Int
  ) {
    let ranges = device.activeFormat.videoSupportedFrameRateRanges
    let selection = CaptureFrameRateSelection.select(
      requestedFrameRate: requestedFrameRate,
      supportedRanges: ranges.map {
        CaptureFrameRateRange(minFrameRate: $0.minFrameRate, maxFrameRate: $0.maxFrameRate)
      }
    )
    let frameDuration: CMTime
    switch selection {
    case .requested(let frameRate):
      frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
    case .rangeMaximum(let index):
      frameDuration = ranges[index].minFrameDuration
    case .rangeMinimum(let index):
      frameDuration = ranges[index].maxFrameDuration
    case .unavailable:
      logger.error(
        "Capture frame rate not applied input=\(inputIndex, privacy: .public) requestedFPS=\(requestedFrameRate, privacy: .public) reason=no-supported-range"
      )
      return
    }
    if abs(1 / frameDuration.seconds - Double(requestedFrameRate))
      > CaptureFrameRateSelection.tolerance
    {
      logger.notice(
        "Capture frame rate unsupported input=\(inputIndex, privacy: .public) requestedFPS=\(requestedFrameRate, privacy: .public) appliedFPS=\(frameRateDescription(for: frameDuration), privacy: .public)"
      )
    }
    // AVFoundation raises an Objective-C exception, which Swift cannot catch, for a
    // duration outside every supported range. Check with exact rational comparison first.
    guard
      ranges.contains(where: {
        CMTimeCompare(frameDuration, $0.minFrameDuration) >= 0
          && CMTimeCompare(frameDuration, $0.maxFrameDuration) <= 0
      })
    else {
      logger.error(
        "Capture frame rate not applied input=\(inputIndex, privacy: .public) requestedFPS=\(requestedFrameRate, privacy: .public) reason=duration-outside-supported-ranges"
      )
      return
    }
    do {
      try AVCaptureDeviceConfigurationGate.withLock {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
      }
    } catch {
      logger.error(
        "Capture frame rate not applied input=\(inputIndex, privacy: .public) requestedFPS=\(requestedFrameRate, privacy: .public) code=\((error as NSError).code, privacy: .public) error=\(String(describing: error), privacy: .private)"
      )
    }
  }

}

enum CaptureSessionRuntimeFailureAction: Equatable {
  case discard
  case restart
  case report
}

enum CaptureSessionRuntimeFailurePolicy {
  // AVErrorMediaServicesWereReset in AVFoundation/AVError.h. The macOS Swift
  // overlay does not expose a named AVError.Code case for this value.
  static let mediaServicesWereResetErrorCode = -11_819

  static func action(
    errorCode: Int,
    observedSessionIsCurrent: Bool
  ) -> CaptureSessionRuntimeFailureAction {
    guard observedSessionIsCurrent else { return .discard }
    if errorCode == mediaServicesWereResetErrorCode {
      return .restart
    }
    return .report
  }
}
