// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXMP4
import LDTXSupport

final class CaptureSessionManager {
    private var dashSegmentWriter: SegmentedMP4Writer?
    private var dashSegmentContinuation: AsyncStream<SegmentedMP4Segment>.Continuation?
    private var dashUploadTask: Task<Void, Never>?
    private var localDASHWriteTask: Task<Void, Never>?
    private var localDASHOutputDirectory: URL?
    private var fileMP4Writer: FileMP4Writer?
    private var fileMP4OutputURL: URL?

    func startLocalDASH(
        writer: SegmentedMP4Writer,
        segmentContinuation: AsyncStream<SegmentedMP4Segment>.Continuation,
        writeTask: Task<Void, Never>,
        outputDirectory: URL
    ) {
        dashSegmentWriter = writer
        dashSegmentContinuation = segmentContinuation
        localDASHWriteTask = writeTask
        localDASHOutputDirectory = outputDirectory
    }

    func startDASHUpload(
        writer: SegmentedMP4Writer,
        segmentContinuation: AsyncStream<SegmentedMP4Segment>.Continuation,
        uploadTask: Task<Void, Never>
    ) {
        dashSegmentWriter = writer
        dashSegmentContinuation = segmentContinuation
        dashUploadTask = uploadTask
    }

    func startMP4(writer: FileMP4Writer, outputURL: URL) {
        fileMP4Writer = writer
        fileMP4OutputURL = outputURL
    }

    func clearLocalDASH() {
        dashSegmentWriter = nil
        dashSegmentContinuation = nil
        localDASHWriteTask = nil
        localDASHOutputDirectory = nil
    }

    func clearDASHUpload() {
        dashSegmentWriter = nil
        dashSegmentContinuation = nil
        dashUploadTask = nil
    }

    func clearMP4() {
        fileMP4Writer = nil
        fileMP4OutputURL = nil
    }

    func takeSegmentWriter() -> SegmentedMP4Writer? {
        let writer = dashSegmentWriter
        dashSegmentWriter = nil
        return writer
    }

    func finishSegmentStream() {
        dashSegmentContinuation?.finish()
        dashSegmentContinuation = nil
    }

    func takeDASHUploadTask() -> Task<Void, Never>? {
        let task = dashUploadTask
        dashUploadTask = nil
        return task
    }

    func takeLocalDASHWriteTaskAndOutputDirectory() -> (
        task: Task<Void, Never>?,
        outputDirectory: URL?
    ) {
        let task = localDASHWriteTask
        let outputDirectory = localDASHOutputDirectory
        localDASHWriteTask = nil
        localDASHOutputDirectory = nil
        return (task, outputDirectory)
    }

    func takeMP4WriterAndOutputURL() -> (
        writer: FileMP4Writer?,
        outputURL: URL?
    ) {
        let writer = fileMP4Writer
        let outputURL = fileMP4OutputURL
        fileMP4Writer = nil
        fileMP4OutputURL = nil
        return (writer, outputURL)
    }
}
