// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXMP4
import OSLog

private let dashManifestLogger = Logger(
  subsystem: "tokyo.kaito.ldtx", category: "DASHManifest")

public enum DASHLiveUploadPipelineEvent: Equatable, Sendable {
  case initializationPrepared(byteCount: Int)
  case manifestUploaded(byteCount: Int)
  case mediaSegmentUploaded(number: Int, byteCount: Int)
}

public struct DASHLiveUploadManifestState: Equatable, Sendable {
  public var startNumber: Int
  public var availabilityStartTime: Date

  public init(startNumber: Int, availabilityStartTime: Date) {
    self.startNumber = startNumber
    self.availabilityStartTime = availabilityStartTime
  }
}

public struct DASHLiveUploadDiagnosticContext: Equatable, Sendable {
  public var sessionID: UUID?
  public var revision: UInt64?

  public init(sessionID: UUID? = nil, revision: UInt64? = nil) {
    self.sessionID = sessionID
    self.revision = revision
  }
}

public enum DASHLiveUploadPipelineError: Error, Equatable, LocalizedError {
  case mediaSegmentBeforeInitialization(Int)
  case mediaSegmentMissingTiming(Int)
  case noncontiguousMediaSegment(expected: Int, actual: Int)
  case nonmonotonicMediaSegment(number: Int, previousStart: Double, actualStart: Double)

  public var errorDescription: String? {
    switch self {
    case .mediaSegmentBeforeInitialization(let number):
      "DASH media segment \(number) was produced before the initialization segment."
    case .mediaSegmentMissingTiming(let number):
      "DASH media segment \(number) does not contain valid presentation timing."
    case .noncontiguousMediaSegment(let expected, let actual):
      "DASH media segment numbering is not contiguous; expected \(expected), got \(actual)."
    case .nonmonotonicMediaSegment(let number, let previousStart, let actualStart):
      "DASH media segment \(number) starts at \(actualStart), not after \(previousStart)."
    }
  }
}

public final class DASHLiveUploadPipeline: @unchecked Sendable {
  private struct PendingUpload: Sendable {
    var segment: SegmentedMP4Segment
    var completionHandler: @Sendable (Result<DASHLiveUploadPipelineEvent, any Error>) -> Void
  }

  private let uploadClient: DASHUploadClient
  private var baseManifestConfiguration: DASHManifestConfiguration
  private let diagnosticContext: DASHLiveUploadDiagnosticContext
  private let manifestStateHandler: @Sendable (DASHLiveUploadManifestState) -> Void
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.DASHLiveUploadPipeline")
  private var uploadedManifest = false
  private var latestInitializationSegment: Data?
  private var segmentTimeline: [DASHSegmentTimelineEntry] = []
  private var pendingUploads: [PendingUpload] = []
  private var isUploading = false

  public init(
    endpoint: DASHIngestEndpoint,
    manifestConfiguration: DASHManifestConfiguration,
    session: any HTTPSession = URLSession.shared,
    retryPolicy: DASHRetryPolicy = DASHRetryPolicy(),
    diagnosticContext: DASHLiveUploadDiagnosticContext = DASHLiveUploadDiagnosticContext(),
    manifestStateHandler: @escaping @Sendable (DASHLiveUploadManifestState) -> Void = { _ in }
  ) {
    uploadClient = DASHUploadClient(
      endpoint: endpoint,
      session: session,
      retryPolicy: retryPolicy
    )
    baseManifestConfiguration = manifestConfiguration
    self.diagnosticContext = diagnosticContext
    self.manifestStateHandler = manifestStateHandler
  }

  public init(
    uploadClient: DASHUploadClient,
    manifestConfiguration: DASHManifestConfiguration,
    diagnosticContext: DASHLiveUploadDiagnosticContext = DASHLiveUploadDiagnosticContext(),
    manifestStateHandler: @escaping @Sendable (DASHLiveUploadManifestState) -> Void = { _ in }
  ) {
    self.uploadClient = uploadClient
    baseManifestConfiguration = manifestConfiguration
    self.diagnosticContext = diagnosticContext
    self.manifestStateHandler = manifestStateHandler
  }

  public func upload(
    _ segment: SegmentedMP4Segment,
    completionHandler: @escaping @Sendable (Result<DASHLiveUploadPipelineEvent, any Error>) -> Void
  ) {
    queue.async { [self] in
      pendingUploads.append(
        PendingUpload(
          segment: segment,
          completionHandler: completionHandler
        ))
      startNextUploadIfNeeded()
    }
  }

  /// Updates the AVC portion of the representation before the initialization
  /// segment causes the first MPD to be generated. Calls are serialized with
  /// segment uploads, so a preceding update is visible to that MPD.
  public func setVideoCodecString(_ codecString: String, audioCodecString: String) {
    queue.async { [self] in
      guard !uploadedManifest else { return }
      baseManifestConfiguration.representation.codecs = "\(codecString),\(audioCodecString)"
    }
  }

  private func startNextUploadIfNeeded() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !isUploading, let upload = pendingUploads.first else {
      return
    }
    isUploading = true
    uploadOnQueue(upload.segment) { [weak self] result in
      guard let self else {
        upload.completionHandler(.failure(CancellationError()))
        return
      }
      self.queue.async {
        if !self.pendingUploads.isEmpty {
          self.pendingUploads.removeFirst()
        }
        self.isUploading = false
        upload.completionHandler(result)
        self.startNextUploadIfNeeded()
      }
    }
  }

  private func uploadOnQueue(
    _ segment: SegmentedMP4Segment,
    completionHandler: @escaping @Sendable (Result<DASHLiveUploadPipelineEvent, any Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    switch segment.kind {
    case .initialization:
      latestInitializationSegment = segment.data
      completionHandler(.success(.initializationPrepared(byteCount: segment.data.count)))

    case .media(let number):
      guard let latestInitializationSegment else {
        completionHandler(
          .failure(DASHLiveUploadPipelineError.mediaSegmentBeforeInitialization(number)))
        return
      }
      do {
        _ = try timelineEntry(for: segment, number: number)
      } catch {
        completionHandler(.failure(error))
        return
      }
      uploadMediaSegment(
        number, segment: segment,
        completionHandler: { [weak self] result in
          guard let self else {
            completionHandler(.failure(CancellationError()))
            return
          }
          self.queue.async {
            switch result {
            case .success:
              if self.segmentTimeline.last?.number == number {
                completionHandler(
                  .success(.mediaSegmentUploaded(number: number, byteCount: segment.data.count)))
                return
              }
              do {
                try self.appendTimelineEntry(for: segment, number: number)
              } catch {
                completionHandler(.failure(error))
                return
              }
              self.publishManifest(
                using: latestInitializationSegment,
                reason: self.uploadedManifest ? "media" : "initial"
              ) { manifestResult in
                switch manifestResult {
                case .success:
                  completionHandler(
                    .success(.mediaSegmentUploaded(number: number, byteCount: segment.data.count)))
                case .failure(let error):
                  completionHandler(.failure(error))
                }
              }
            case .failure(let error):
              completionHandler(.failure(error))
            }
          }
        })
    }
  }

  private func publishManifest(
    using initializationSegment: Data,
    reason: String,
    completionHandler: @escaping @Sendable (Result<DASHLiveUploadPipelineEvent, any Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let number = segmentTimeline.first?.number else {
      completionHandler(.failure(DASHLiveUploadPipelineError.mediaSegmentMissingTiming(0)))
      return
    }
    let manifest: String
    do {
      manifest = try refreshedManifest(using: initializationSegment)
    } catch {
      completionHandler(.failure(error))
      return
    }
    uploadClient.put(.manifest(manifest)) { [weak self] result in
      guard let self else {
        completionHandler(.failure(CancellationError()))
        return
      }
      self.queue.async {
        switch result {
        case .failure(let error):
          completionHandler(.failure(error))
        case .success(let response):
          self.uploadedManifest = true
          self.manifestStateHandler(self.manifestState())
          let diagnosticSession = self.diagnosticContext.sessionID?.uuidString ?? "unavailable"
          let diagnosticRevision =
            self.diagnosticContext.revision.map(String.init)
            ?? "unavailable"
          dashManifestLogger.notice(
            "[event:dash.manifest.published] session=\(diagnosticSession, privacy: .public) revision=\(diagnosticRevision, privacy: .public) reason=\(reason, privacy: .public) startSegment=\(number, privacy: .public) availabilityStartMs=\(Self.epochMilliseconds(self.baseManifestConfiguration.availabilityStartTime), privacy: .public) bytes=\(manifest.utf8.count, privacy: .public) status=\(response.statusCode, privacy: .public)"
          )
          completionHandler(.success(.manifestUploaded(byteCount: manifest.utf8.count)))
        }
      }
    }
  }

  private func uploadMediaSegment(
    _ number: Int,
    segment: SegmentedMP4Segment,
    completionHandler: @escaping @Sendable (Result<DASHLiveUploadPipelineEvent, any Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    let object: DASHUploadObject
    do {
      object = try .mediaSegment(number: number, data: segment.data)
    } catch {
      completionHandler(.failure(error))
      return
    }
    uploadClient.put(object) { [weak self] result in
      switch result {
      case .success:
        completionHandler(
          .success(
            .mediaSegmentUploaded(
              number: number,
              byteCount: segment.data.count
            )))
      case .failure(let error as DASHUploadError):
        guard case .missingManifestOrInitialization = error,
          let self
        else {
          completionHandler(.failure(error))
          return
        }
        self.queue.async {
          self.recoverAndUploadMedia(
            object,
            segment: segment,
            number: number,
            byteCount: segment.data.count,
            completionHandler: completionHandler
          )
        }
      case .failure(let error):
        completionHandler(.failure(error))
      }
    }
  }

  private func recoverAndUploadMedia(
    _ object: DASHUploadObject,
    segment: SegmentedMP4Segment,
    number: Int,
    byteCount: Int,
    completionHandler: @escaping @Sendable (Result<DASHLiveUploadPipelineEvent, any Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let latestInitializationSegment else {
      completionHandler(
        .failure(
          DASHUploadError.missingManifestOrInitialization(
            objectName: object.name.rawValue,
            byteCount: object.data.count,
            statusCode: 409,
            body: Data()
          )))
      return
    }
    let timelineBeforeRecovery = segmentTimeline
    do {
      try appendTimelineEntry(for: segment, number: number)
    } catch {
      completionHandler(.failure(error))
      return
    }
    let manifest: String
    do {
      manifest = try refreshedManifest(using: latestInitializationSegment)
    } catch {
      segmentTimeline = timelineBeforeRecovery
      completionHandler(.failure(error))
      return
    }
    uploadClient.put(.manifest(manifest)) { [weak self] result in
      guard let self else {
        completionHandler(.failure(CancellationError()))
        return
      }
      self.queue.async {
        switch result {
        case .failure(let error):
          self.segmentTimeline = timelineBeforeRecovery
          completionHandler(.failure(error))
        case .success(let response):
          self.manifestStateHandler(self.manifestState())
          let diagnosticSession = self.diagnosticContext.sessionID?.uuidString ?? "unavailable"
          let diagnosticRevision =
            self.diagnosticContext.revision.map(String.init)
            ?? "unavailable"
          dashManifestLogger.notice(
            "[event:dash.manifest.published] session=\(diagnosticSession, privacy: .public) revision=\(diagnosticRevision, privacy: .public) reason=http409Recovery startSegment=\(number, privacy: .public) availabilityStartMs=\(Self.epochMilliseconds(self.baseManifestConfiguration.availabilityStartTime), privacy: .public) bytes=\(manifest.utf8.count, privacy: .public) status=\(response.statusCode, privacy: .public)"
          )
          self.uploadClient.put(object) { result in
            self.queue.async {
              switch result {
              case .success:
                completionHandler(
                  .success(.mediaSegmentUploaded(number: number, byteCount: byteCount)))
              case .failure(let error):
                self.segmentTimeline = timelineBeforeRecovery
                self.publishRecoveryRetraction(
                  using: latestInitializationSegment,
                  completionHandler: { completionHandler(.failure(error)) }
                )
              }
            }
          }
        }
      }
    }
  }

  private func publishRecoveryRetraction(
    using initializationSegment: Data,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    let manifest: String
    do {
      manifest = try refreshedManifest(
        using: initializationSegment,
        allowsEmptyTimeline: true
      )
    } catch {
      completionHandler()
      return
    }
    uploadClient.put(.manifest(manifest)) { [weak self] result in
      guard let self else {
        completionHandler()
        return
      }
      self.queue.async {
        if case .success = result {
          self.manifestStateHandler(self.manifestState())
        }
        completionHandler()
      }
    }
  }

  private func refreshedManifest(
    using initializationSegment: Data,
    allowsEmptyTimeline: Bool = false
  ) throws -> String {
    var manifestConfiguration = baseManifestConfiguration
    manifestConfiguration.startNumber =
      segmentTimeline.first?.number
      ?? baseManifestConfiguration.startNumber
    manifestConfiguration.segmentTimeline = segmentTimeline
    manifestConfiguration.initialization = .embedded(data: initializationSegment)
    return try DASHManifestGenerator.xml(
      configuration: manifestConfiguration,
      allowsEmptyTimeline: allowsEmptyTimeline
    )
  }

  private func manifestState() -> DASHLiveUploadManifestState {
    return DASHLiveUploadManifestState(
      startNumber: segmentTimeline.first?.number ?? baseManifestConfiguration.startNumber,
      availabilityStartTime: baseManifestConfiguration.availabilityStartTime
    )
  }

  private func appendTimelineEntry(
    for segment: SegmentedMP4Segment,
    number: Int
  ) throws {
    if segmentTimeline.last?.number == number {
      return
    }
    let entry = try timelineEntry(for: segment, number: number)
    segmentTimeline.append(entry)
    let cutoff =
      entry.startTimeSeconds - Double(baseManifestConfiguration.timeShiftBufferDepthSeconds)
    segmentTimeline.removeAll { $0.startTimeSeconds + $0.durationSeconds < cutoff }
  }

  private func timelineEntry(
    for segment: SegmentedMP4Segment,
    number: Int
  ) throws -> DASHSegmentTimelineEntry {
    guard let start = segment.earliestPresentationTimeSeconds,
      let duration = segment.durationSeconds,
      start.isFinite, start >= 0, duration.isFinite, duration > 0
    else { throw DASHLiveUploadPipelineError.mediaSegmentMissingTiming(number) }
    if let last = segmentTimeline.last {
      guard number == last.number + 1 else {
        throw DASHLiveUploadPipelineError.noncontiguousMediaSegment(
          expected: last.number + 1, actual: number)
      }
      guard start > last.startTimeSeconds else {
        throw DASHLiveUploadPipelineError.nonmonotonicMediaSegment(
          number: number, previousStart: last.startTimeSeconds, actualStart: start)
      }
    }
    return DASHSegmentTimelineEntry(
      number: number, startTimeSeconds: start, durationSeconds: duration)
  }

  private func removeTimelineEntry(number: Int) {
    guard segmentTimeline.last?.number == number else { return }
    segmentTimeline.removeLast()
  }

  private static func epochMilliseconds(_ date: Date) -> Int64 {
    Int64(clamping: Int((date.timeIntervalSince1970 * 1_000).rounded()))
  }
}
