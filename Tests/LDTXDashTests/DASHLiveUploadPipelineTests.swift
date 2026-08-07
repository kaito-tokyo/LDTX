// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXMP4
import Testing

struct DASHLiveUploadPipelineTests {
  @Test func uploadsManifestFromInitializationThenMediaSegment() async throws {
    let recorder = DASHUploadRequestRecorder()
    let session = DASHLiveUploadMockHTTPSession { request in
      await recorder.append(request)
      return (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let client = DASHUploadClient(
      endpoint: DASHIngestEndpoint(
        baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
      session: session,
      retryPolicy: DASHRetryPolicy(maxAttempts: 1)
    )
    let pipeline = DASHLiveUploadPipeline(
      uploadClient: client,
      manifestConfiguration: DASHManifestConfiguration(
        availabilityStartTime: Date(timeIntervalSince1970: 1_704_067_200),
        initialization: .embedded(data: Data()),
        representation: .default1080p60
      )
    )
    pipeline.setVideoCodecString("avc1.640c2a", audioCodecString: "mp4a.40.2")

    let initializationEvent = try await upload(
      pipeline,
      SegmentedMP4Segment(kind: .initialization, data: Data([0x00, 0x01, 0x02]))
    )
    #expect(await recorder.requests.isEmpty)
    let mediaEvent = try await upload(
      pipeline,
      SegmentedMP4Segment(
        kind: .media(number: 1), data: Data([0x03, 0x04]),
        durationSeconds: 1, earliestPresentationTimeSeconds: 1)
    )

    #expect(
      initializationEvent == .initializationPrepared(byteCount: 3))
    #expect(mediaEvent == .mediaSegmentUploaded(number: 1, byteCount: 2))

    let requests = await recorder.requests
    #expect(
      requests.map(\.url?.absoluteString) == [
        "https://upload.youtube.com/dash_upload?cid=abc&file=media000000001.mp4",
        "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd",
      ])
    #expect(requests.first?.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
    #expect(requests.last?.value(forHTTPHeaderField: "Content-Type") == "application/dash+xml")
    #expect(
      String(data: requests.last?.httpBody ?? Data(), encoding: .utf8)?.contains("AAEC") == true)
    #expect(
      String(data: requests.last?.httpBody ?? Data(), encoding: .utf8)?
        .contains("codecs=\"avc1.640c2a,mp4a.40.2\"") == true)
  }

  @Test func rejectsMediaBeforeInitialization() async throws {
    let client = DASHUploadClient(
      endpoint: DASHIngestEndpoint(
        baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
      session: DASHLiveUploadMockHTTPSession { request in
        Issue.record("Unexpected request: \(request)")
        return (
          Data(),
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }
    )
    let pipeline = DASHLiveUploadPipeline(
      uploadClient: client,
      manifestConfiguration: DASHManifestConfiguration(initialization: .embedded(data: Data()))
    )

    do {
      _ = try await upload(
        pipeline,
        SegmentedMP4Segment(kind: .media(number: 1), data: Data([0x03, 0x04]))
      )
      Issue.record("Expected media-before-initialization error")
    } catch let error as DASHLiveUploadPipelineError {
      #expect(error == .mediaSegmentBeforeInitialization(1))
    }
  }

  @Test func failedMediaUploadIsNotAdvertisedInTheManifest() async throws {
    let recorder = DASHUploadRequestRecorder()
    let session = DASHLiveUploadMockHTTPSession { request in
      await recorder.append(request)
      return (
        Data("unavailable".utf8),
        HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
      )
    }
    let pipeline = DASHLiveUploadPipeline(
      uploadClient: DASHUploadClient(
        endpoint: DASHIngestEndpoint(
          baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
        session: session,
        retryPolicy: DASHRetryPolicy(maxAttempts: 1)
      ),
      manifestConfiguration: DASHManifestConfiguration(initialization: .embedded(data: Data()))
    )

    _ = try await upload(
      pipeline, SegmentedMP4Segment(kind: .initialization, data: Data([0x00])))
    await #expect(throws: DASHUploadError.self) {
      try await upload(
        pipeline,
        SegmentedMP4Segment(
          kind: .media(number: 1), data: Data([0x01]), durationSeconds: 1,
          earliestPresentationTimeSeconds: 0)
      )
    }

    let requests = await recorder.requests
    #expect(requests.map(\.url?.absoluteString) == [
      "https://upload.youtube.com/dash_upload?cid=abc&file=media000000001.mp4"
    ])
  }

  @Test func refreshesManifestAndRetriesMediaOnceAfterConflict() async throws {
    let recorder = DASHUploadRequestRecorder()
    let session = DASHLiveUploadMockHTTPSession { request in
      await recorder.append(request)
      let isFirstMediaRequest =
        await recorder.requests.filter {
          $0.url?.absoluteString
            == "https://upload.youtube.com/dash_upload?cid=abc&file=media000000042.mp4"
        }.count == 1
      if request.url?.absoluteString
        == "https://upload.youtube.com/dash_upload?cid=abc&file=media000000042.mp4",
        isFirstMediaRequest
      {
        return (
          Data("conflict".utf8),
          HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
        )
      }
      return (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let client = DASHUploadClient(
      endpoint: DASHIngestEndpoint(
        baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
      session: session,
      retryPolicy: DASHRetryPolicy(maxAttempts: 1)
    )
    let pipeline = DASHLiveUploadPipeline(
      uploadClient: client,
      manifestConfiguration: DASHManifestConfiguration(
        availabilityStartTime: Date(timeIntervalSince1970: 1_800_000_000),
        startNumber: 42,
        initialization: .embedded(data: Data()),
        representation: .default1080p60
      )
    )

    _ = try await upload(
      pipeline,
      SegmentedMP4Segment(kind: .initialization, data: Data([0x00, 0x01, 0x02]))
    )
    let event = try await upload(
      pipeline,
      SegmentedMP4Segment(
        kind: .media(number: 42), data: Data([0x03, 0x04]),
        durationSeconds: 1.5, earliestPresentationTimeSeconds: 81.25)
    )

    #expect(event == .mediaSegmentUploaded(number: 42, byteCount: 2))
    let requests = await recorder.requests
    #expect(
      requests.map(\.url?.absoluteString) == [
        "https://upload.youtube.com/dash_upload?cid=abc&file=media000000042.mp4",
        "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd",
        "https://upload.youtube.com/dash_upload?cid=abc&file=media000000042.mp4",
      ])
    let refreshedManifest = String(data: requests[1].httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(refreshedManifest.contains(#"startNumber="42""#))
    #expect(refreshedManifest.contains(#"availabilityStartTime="2027-01-15T08:00:00Z""#))
    #expect(refreshedManifest.contains("AAEC"))
  }

  @Test func retractsRecoveryManifestWhenRetriedMediaFails() async throws {
    let recorder = DASHUploadRequestRecorder()
    let mediaURL = "https://upload.youtube.com/dash_upload?cid=abc&file=media000000002.mp4"
    let session = DASHLiveUploadMockHTTPSession { request in
      await recorder.append(request)
      let mediaRequestCount = await recorder.requests.filter {
        $0.url?.absoluteString == mediaURL
      }.count
      let statusCode = request.url?.absoluteString == mediaURL
        ? (mediaRequestCount == 1 ? 409 : 503)
        : 200
      return (
        Data(),
        HTTPURLResponse(
          url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
      )
    }
    let pipeline = DASHLiveUploadPipeline(
      uploadClient: DASHUploadClient(
        endpoint: DASHIngestEndpoint(
          baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
        session: session,
        retryPolicy: DASHRetryPolicy(maxAttempts: 1)
      ),
      manifestConfiguration: DASHManifestConfiguration(
        timeShiftBufferDepthSeconds: 60,
        startNumber: 1,
        initialization: .embedded(data: Data())
      )
    )

    _ = try await upload(
      pipeline, SegmentedMP4Segment(kind: .initialization, data: Data([0x00])))
    _ = try await upload(
      pipeline,
      SegmentedMP4Segment(
        kind: .media(number: 1), data: Data([0x01]), durationSeconds: 1,
        earliestPresentationTimeSeconds: 0)
    )
    await #expect(throws: DASHUploadError.self) {
      try await upload(
        pipeline,
        SegmentedMP4Segment(
          kind: .media(number: 2), data: Data([0x02]), durationSeconds: 1,
          earliestPresentationTimeSeconds: 100)
      )
    }

    let requests = await recorder.requests
    #expect(requests.count == 6)
    #expect(requests[2].url?.absoluteString == mediaURL)
    #expect(requests[3].url?.absoluteString.hasSuffix("file=source.mpd") == true)
    #expect(requests[4].url?.absoluteString == mediaURL)
    #expect(requests[5].url?.absoluteString.hasSuffix("file=source.mpd") == true)
    let advertisedManifest = String(data: requests[3].httpBody ?? Data(), encoding: .utf8) ?? ""
    let retractedManifest = String(data: requests[5].httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(advertisedManifest.contains(#"<S t="100000" d="1000"/>"#))
    #expect(!advertisedManifest.contains(#"<S t="0" d="1000"/>"#))
    #expect(retractedManifest.contains(#"<S t="0" d="1000"/>"#))
    #expect(!retractedManifest.contains(#"<S t="100000" d="1000"/>"#))
  }

  @Test func publishesActualTimelineBeforeEveryMediaSegment() async throws {
    let recorder = DASHUploadRequestRecorder()
    let manifestStates = DASHManifestStateRecorder()
    let session = DASHLiveUploadMockHTTPSession { request in
      await recorder.append(request)
      return (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let client = DASHUploadClient(
      endpoint: DASHIngestEndpoint(
        baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
      session: session,
      retryPolicy: DASHRetryPolicy(maxAttempts: 1)
    )
    let pipeline = DASHLiveUploadPipeline(
      uploadClient: client,
      manifestConfiguration: DASHManifestConfiguration(
        availabilityStartTime: Date(timeIntervalSince1970: 1_704_067_200),
        minimumUpdatePeriodSeconds: 5,
        startNumber: 10,
        initialization: .embedded(data: Data()),
        representation: .default1080p60
      ),
      manifestStateHandler: { state in
        manifestStates.append(state)
      }
    )

    _ = try await upload(
      pipeline,
      SegmentedMP4Segment(kind: .initialization, data: Data([0x00, 0x01, 0x02]))
    )
    let timings: [(Double, Double)] = [(1, 0.2), (1.2, 1), (2.2, 2.04), (4.24, 4.2)]
    for (number, timing) in zip(10...13, timings) {
      _ = try await upload(
        pipeline,
        SegmentedMP4Segment(
          kind: .media(number: number), data: Data([UInt8(number)]),
          durationSeconds: timing.1, earliestPresentationTimeSeconds: timing.0)
      )
    }

    let requests = await recorder.requests
    #expect(
      requests.map(\.url?.absoluteString) == [
        "https://upload.youtube.com/dash_upload?cid=abc&file=media000000010.mp4",
        "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd",
        "https://upload.youtube.com/dash_upload?cid=abc&file=media000000011.mp4",
        "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd",
        "https://upload.youtube.com/dash_upload?cid=abc&file=media000000012.mp4",
        "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd",
        "https://upload.youtube.com/dash_upload?cid=abc&file=media000000013.mp4",
        "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd",
      ])
    let refreshedManifest = String(data: requests[7].httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(refreshedManifest.contains(#"startNumber="10""#))
    #expect(refreshedManifest.contains(#"availabilityStartTime="2024-01-01T00:00:00Z""#))
    #expect(refreshedManifest.contains(#"<S t="1000" d="200"/>"#))
    #expect(refreshedManifest.contains(#"<S t="4240" d="4200"/>"#))
    #expect(!refreshedManifest.contains(#" duration=""#))
    let states = manifestStates.values
    #expect(states.last?.startNumber == 10)
    #expect(states.last?.availabilityStartTime == Date(timeIntervalSince1970: 1_704_067_200))
  }

  @Test func conflictRecoveryKeepsPeriodicallyAdvancedManifestTimeline() async throws {
    let recorder = DASHUploadRequestRecorder()
    let session = DASHLiveUploadMockHTTPSession { request in
      await recorder.append(request)
      let media14URL =
        "https://upload.youtube.com/dash_upload?cid=abc&file=media000000014.mp4"
      let media14RequestCount = await recorder.requests.filter {
        $0.url?.absoluteString == media14URL
      }.count
      let statusCode = request.url?.absoluteString == media14URL && media14RequestCount == 1
        ? 409 : 200
      return (
        Data(),
        HTTPURLResponse(
          url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
      )
    }
    let pipeline = DASHLiveUploadPipeline(
      uploadClient: DASHUploadClient(
        endpoint: DASHIngestEndpoint(
          baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
        session: session,
        retryPolicy: DASHRetryPolicy(maxAttempts: 1)
      ),
      manifestConfiguration: DASHManifestConfiguration(
        availabilityStartTime: Date(timeIntervalSince1970: 1_704_067_200),
        minimumUpdatePeriodSeconds: 5,
        startNumber: 10,
        initialization: .embedded(data: Data()),
        representation: .default1080p60
      )
    )

    _ = try await upload(
      pipeline,
      SegmentedMP4Segment(kind: .initialization, data: Data([0x00, 0x01, 0x02]))
    )
    for number in 10...16 {
      _ = try await upload(
        pipeline,
        SegmentedMP4Segment(
          kind: .media(number: number), data: Data([UInt8(number)]),
          durationSeconds: Double(number - 8) / 10,
          earliestPresentationTimeSeconds: Double(number - 10) * 1.5)
      )
    }

    let requests = await recorder.requests
    let manifests = requests.filter { $0.url?.absoluteString.hasSuffix("file=source.mpd") == true }
    #expect(manifests.count == 7)
    let recoveryManifest = String(data: manifests[5].httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(recoveryManifest.contains(#"startNumber="10""#))
    #expect(recoveryManifest.contains(#"<S t="6000" d="600"/>"#))
    #expect(recoveryManifest.contains(#"availabilityStartTime="2024-01-01T00:00:00Z""#))
  }

  @Test func initialManifestFailureIsReportedWhenFirstMediaArrives() async throws {
    let recorder = DASHUploadRequestRecorder()
    let session = DASHLiveUploadMockHTTPSession { request in
      await recorder.append(request)
      return (
        Data("conflict".utf8),
        HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
      )
    }
    let client = DASHUploadClient(
      endpoint: DASHIngestEndpoint(
        baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
      session: session,
      retryPolicy: DASHRetryPolicy(maxAttempts: 1)
    )
    let pipeline = DASHLiveUploadPipeline(
      uploadClient: client,
      manifestConfiguration: DASHManifestConfiguration(
        availabilityStartTime: Date(timeIntervalSince1970: 1_800_000_000),
        initialization: .embedded(data: Data()),
        representation: .default1080p60
      )
    )

    _ = try await upload(
      pipeline,
      SegmentedMP4Segment(kind: .initialization, data: Data([0x00, 0x01, 0x02]))
    )
    #expect(await recorder.requests.isEmpty)

    do {
      _ = try await upload(
        pipeline,
        SegmentedMP4Segment(
          kind: .media(number: 1), data: Data([0x03, 0x04]),
          durationSeconds: 2, earliestPresentationTimeSeconds: 1)
      )
      Issue.record("Expected initialization upload conflict")
    } catch let error as DASHUploadError {
      guard
        case .missingManifestOrInitialization(
          let
            objectName,
          let
            byteCount,
          let
            statusCode,
          let
            body
        ) = error
      else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(objectName == "source.mpd")
      #expect(byteCount > 0)
      #expect(statusCode == 409)
      #expect(body == Data("conflict".utf8))
    }

    let requests = await recorder.requests
    #expect(requests.count == 2)
    #expect(requests[0].url?.absoluteString.hasSuffix("file=media000000001.mp4") == true)
    #expect(requests[1].url?.absoluteString.hasSuffix("file=source.mpd") == true)
  }

  @Test func evictsTimelineByActualPresentationWindowWithoutMovingAvailabilityStart() async throws {
    let recorder = DASHUploadRequestRecorder()
    let session = DASHLiveUploadMockHTTPSession { request in
      await recorder.append(request)
      return (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let pipeline = DASHLiveUploadPipeline(
      uploadClient: DASHUploadClient(
        endpoint: DASHIngestEndpoint(
          baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
        session: session,
        retryPolicy: DASHRetryPolicy(maxAttempts: 1)
      ),
      manifestConfiguration: DASHManifestConfiguration(
        availabilityStartTime: Date(timeIntervalSince1970: 1_704_067_200),
        timeShiftBufferDepthSeconds: 60,
        startNumber: 7,
        initialization: .embedded(data: Data()))
    )

    _ = try await upload(
      pipeline, SegmentedMP4Segment(kind: .initialization, data: Data([1])))
    _ = try await upload(
      pipeline,
      SegmentedMP4Segment(
        kind: .media(number: 7), data: Data([7]), durationSeconds: 1,
        earliestPresentationTimeSeconds: 1))
    _ = try await upload(
      pipeline,
      SegmentedMP4Segment(
        kind: .media(number: 8), data: Data([8]), durationSeconds: 0.5,
        earliestPresentationTimeSeconds: 63))

    let manifests = await recorder.requests.filter {
      $0.url?.absoluteString.hasSuffix("file=source.mpd") == true
    }
    let latest = String(data: manifests.last?.httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(latest.contains(#"startNumber="8""#))
    #expect(latest.contains(#"<S t="63000" d="500"/>"#))
    #expect(!latest.contains(#"<S t="1000" d="1000"/>"#))
    #expect(latest.contains(#"availabilityStartTime="2024-01-01T00:00:00Z""#))
  }

  @Test func rejectsMissingTimingAndNoncontiguousSegmentNumbers() async throws {
    let session = DASHLiveUploadMockHTTPSession { request in
      return (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let pipeline = DASHLiveUploadPipeline(
      uploadClient: DASHUploadClient(
        endpoint: DASHIngestEndpoint(
          baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
        session: session),
      manifestConfiguration: DASHManifestConfiguration(initialization: .embedded(data: Data())))
    _ = try await upload(
      pipeline, SegmentedMP4Segment(kind: .initialization, data: Data([1])))

    do {
      _ = try await upload(
        pipeline, SegmentedMP4Segment(kind: .media(number: 1), data: Data([1])))
      Issue.record("Expected missing timing error")
    } catch let error as DASHLiveUploadPipelineError {
      #expect(error == .mediaSegmentMissingTiming(1))
    }

    _ = try await upload(
      pipeline,
      SegmentedMP4Segment(
        kind: .media(number: 1), data: Data([1]), durationSeconds: 1,
        earliestPresentationTimeSeconds: 0))
    do {
      _ = try await upload(
        pipeline,
        SegmentedMP4Segment(
          kind: .media(number: 3), data: Data([3]), durationSeconds: 1,
          earliestPresentationTimeSeconds: 1))
      Issue.record("Expected noncontiguous numbering error")
    } catch let error as DASHLiveUploadPipelineError {
      #expect(error == .noncontiguousMediaSegment(expected: 2, actual: 3))
    }
  }
}

private actor DASHUploadRequestRecorder {
  private var storedRequests: [URLRequest] = []

  var requests: [URLRequest] {
    storedRequests
  }

  func append(_ request: URLRequest) {
    storedRequests.append(request)
  }
}

private final class DASHManifestStateRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [DASHLiveUploadManifestState] = []

  var values: [DASHLiveUploadManifestState] { lock.withLock { storedValues } }

  func append(_ value: DASHLiveUploadManifestState) {
    lock.withLock { storedValues.append(value) }
  }
}

private final class DASHLiveUploadMockHTTPSession: HTTPSession, @unchecked Sendable {
  private let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
    self.handler = handler
  }

  func data(
    for request: URLRequest,
    completionHandler: @escaping @Sendable (Result<(Data, URLResponse), any Error>) -> Void
  ) {
    Task {
      do {
        completionHandler(.success(try await handler(request)))
      } catch {
        completionHandler(.failure(error))
      }
    }
  }
}

private func upload(
  _ pipeline: DASHLiveUploadPipeline,
  _ segment: SegmentedMP4Segment
) async throws -> DASHLiveUploadPipelineEvent {
  try await withCheckedThrowingContinuation { continuation in
    pipeline.upload(segment) { result in
      continuation.resume(with: result)
    }
  }
}
