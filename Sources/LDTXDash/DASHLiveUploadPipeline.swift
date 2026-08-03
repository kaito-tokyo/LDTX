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

  public var errorDescription: String? {
    switch self {
    case .mediaSegmentBeforeInitialization(let number):
      "DASH media segment \(number) was produced before the initialization segment."
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
  private var manifestStartNumber: Int?
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
      guard uploadedManifest else {
        publishInitialManifest(
          using: latestInitializationSegment,
          beforeMediaSegment: number
        ) { [weak self] result in
          guard let self else {
            completionHandler(.failure(CancellationError()))
            return
          }
          self.queue.async {
            switch result {
            case .success:
              self.uploadMediaSegment(
                number, data: segment.data, completionHandler: completionHandler)
            case .failure(let error):
              completionHandler(.failure(error))
            }
          }
        }
        return
      }
      if shouldRefreshManifest(beforeMediaSegment: number) {
        refreshManifest(beforeMediaSegment: number) { [weak self] result in
          guard let self else {
            completionHandler(.failure(CancellationError()))
            return
          }
          self.queue.async {
            switch result {
            case .success:
              self.uploadMediaSegment(
                number, data: segment.data, completionHandler: completionHandler)
            case .failure(let error):
              completionHandler(.failure(error))
            }
          }
        }
        return
      }
      uploadMediaSegment(number, data: segment.data, completionHandler: completionHandler)
    }
  }

  private func publishInitialManifest(
    using initializationSegment: Data,
    beforeMediaSegment number: Int,
    completionHandler: @escaping @Sendable (Result<DASHLiveUploadPipelineEvent, any Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    let manifest: String
    do {
      manifest = try refreshedManifest(using: initializationSegment, startNumber: number)
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
          self.manifestStartNumber = number
          self.manifestStateHandler(self.manifestState(startNumber: number))
          let diagnosticSession = self.diagnosticContext.sessionID?.uuidString ?? "unavailable"
          let diagnosticRevision = self.diagnosticContext.revision.map(String.init)
            ?? "unavailable"
          dashManifestLogger.notice(
            "[event:dash.manifest.published] session=\(diagnosticSession, privacy: .public) revision=\(diagnosticRevision, privacy: .public) reason=initial startSegment=\(number, privacy: .public) availabilityStartMs=\(Self.epochMilliseconds(self.manifestState(startNumber: number).availabilityStartTime), privacy: .public) bytes=\(manifest.utf8.count, privacy: .public) status=\(response.statusCode, privacy: .public)"
          )
          completionHandler(.success(.manifestUploaded(byteCount: manifest.utf8.count)))
        }
      }
    }
  }

  private func uploadMediaSegment(
    _ number: Int,
    data: Data,
    completionHandler: @escaping @Sendable (Result<DASHLiveUploadPipelineEvent, any Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    let object: DASHUploadObject
    do {
      object = try .mediaSegment(number: number, data: data)
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
              byteCount: data.count
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
            number: number,
            byteCount: data.count,
            completionHandler: completionHandler
          )
        }
      case .failure(let error):
        completionHandler(.failure(error))
      }
    }
  }

  private func shouldRefreshManifest(beforeMediaSegment number: Int) -> Bool {
    guard let manifestStartNumber else { return false }
    let elapsedSegments = number - manifestStartNumber
    return elapsedSegments * baseManifestConfiguration.segmentDurationSeconds
      >= baseManifestConfiguration.minimumUpdatePeriodSeconds
  }

  private func refreshManifest(
    beforeMediaSegment number: Int,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let latestInitializationSegment else {
      completionHandler(
        .failure(DASHLiveUploadPipelineError.mediaSegmentBeforeInitialization(number)))
      return
    }
    let manifest: String
    do {
      manifest = try refreshedManifest(
        using: latestInitializationSegment,
        startNumber: number
      )
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
        case .success(let response):
          self.manifestStartNumber = number
          self.manifestStateHandler(self.manifestState(startNumber: number))
          let diagnosticSession = self.diagnosticContext.sessionID?.uuidString ?? "unavailable"
          let diagnosticRevision = self.diagnosticContext.revision.map(String.init)
            ?? "unavailable"
          dashManifestLogger.info(
            "[event:dash.manifest.published] session=\(diagnosticSession, privacy: .public) revision=\(diagnosticRevision, privacy: .public) reason=periodic startSegment=\(number, privacy: .public) availabilityStartMs=\(Self.epochMilliseconds(self.manifestState(startNumber: number).availabilityStartTime), privacy: .public) bytes=\(manifest.utf8.count, privacy: .public) status=\(response.statusCode, privacy: .public)"
          )
          completionHandler(.success(()))
        case .failure(let error):
          completionHandler(.failure(error))
        }
      }
    }
  }

  private func recoverAndUploadMedia(
    _ object: DASHUploadObject,
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
    let manifest: String
    do {
      manifest = try refreshedManifest(
        using: latestInitializationSegment,
        startNumber: number
      )
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
          self.manifestStartNumber = number
          self.manifestStateHandler(self.manifestState(startNumber: number))
          let diagnosticSession = self.diagnosticContext.sessionID?.uuidString ?? "unavailable"
          let diagnosticRevision = self.diagnosticContext.revision.map(String.init)
            ?? "unavailable"
          dashManifestLogger.notice(
            "[event:dash.manifest.published] session=\(diagnosticSession, privacy: .public) revision=\(diagnosticRevision, privacy: .public) reason=http409Recovery startSegment=\(number, privacy: .public) availabilityStartMs=\(Self.epochMilliseconds(self.manifestState(startNumber: number).availabilityStartTime), privacy: .public) bytes=\(manifest.utf8.count, privacy: .public) status=\(response.statusCode, privacy: .public)"
          )
          self.uploadClient.put(object) { result in
            completionHandler(
              result.map { _ in
                .mediaSegmentUploaded(number: number, byteCount: byteCount)
              })
          }
        }
      }
    }
  }

  private func refreshedManifest(
    using initializationSegment: Data,
    startNumber: Int? = nil
  ) throws -> String {
    var manifestConfiguration = baseManifestConfiguration
    if let startNumber {
      let segmentOffset = startNumber - baseManifestConfiguration.startNumber
      manifestConfiguration.startNumber = startNumber
      manifestConfiguration.availabilityStartTime = baseManifestConfiguration.availabilityStartTime
        .addingTimeInterval(
          Double(segmentOffset * baseManifestConfiguration.segmentDurationSeconds)
        )
    }
    manifestConfiguration.initialization = .embedded(data: initializationSegment)
    return try DASHManifestGenerator.xml(configuration: manifestConfiguration)
  }

  private func manifestState(startNumber: Int) -> DASHLiveUploadManifestState {
    let segmentOffset = startNumber - baseManifestConfiguration.startNumber
    return DASHLiveUploadManifestState(
      startNumber: startNumber,
      availabilityStartTime: baseManifestConfiguration.availabilityStartTime.addingTimeInterval(
        Double(segmentOffset * baseManifestConfiguration.segmentDurationSeconds)
      )
    )
  }

  private static func epochMilliseconds(_ date: Date) -> Int64 {
    Int64(clamping: Int((date.timeIntervalSince1970 * 1_000).rounded()))
  }
}
