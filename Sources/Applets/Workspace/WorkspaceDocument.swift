// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Observation
import SwiftUI
import UniformTypeIdentifiers
import os

@MainActor
protocol WorkspaceDocumentEditingConnection: AnyObject {
  var canReloadDocument: Bool { get }
  func snapshotForSaving() -> WorkspaceDocument.Writer.Snapshot
  func documentDidRead(_ workspace: WorkspaceV4Bundle, previous: WorkspaceV4Bundle?)
  func documentDidSave(_ receipt: WorkspaceDocument.WriteReceipt)
  func documentURLDidChange(_ url: URL)
  func documentDidFail(_ error: Error)
}

@MainActor
@Observable
public final class WorkspaceDocument: Document, WorkspaceDocumentContext {
  public nonisolated static let readableContentTypes = [
    UTType(exportedAs: "tokyo.kaito.ldtx.workspace", conformingTo: .package)
  ]
  public private(set) var confirmedWorkspace: WorkspaceV4Bundle?
  private let configuration: URLDocumentConfiguration?
  private var initialURL: URL?
  @ObservationIgnored weak var editingConnection: (any WorkspaceDocumentEditingConnection)?
  @ObservationIgnored private var configurationTask: Task<Void, Never>?
  private let receipts = OSAllocatedUnfairLock<[WriteReceipt]>(initialState: [])

  public var fileURL: URL? { configuration?.fileURL ?? initialURL }
  public var runtimeWorkspace: WorkspaceV4Bundle? { confirmedWorkspace }

  public init(configuration: URLDocumentConfiguration? = nil) {
    self.configuration = configuration
    initialURL = configuration?.fileURL
    if let configuration {
      let changes = Observations {
        (configuration.fileURL, configuration.lastContentModificationDate)
      }
      configurationTask = Task { @MainActor [weak self] in
        for await (url, date) in changes {
          guard let self, !Task.isCancelled else { return }
          if let url { adoptDocumentURL(url) }
          if date != nil { await acceptPersistedWrite() }
        }
      }
    }
  }

  isolated deinit { configurationTask?.cancel() }

  func adoptDocumentURL(_ url: URL) {
    initialURL = url
    editingConnection?.documentURLDidChange(url)
  }

  public nonisolated func reader(configuration: sending ReadConfiguration) -> sending Reader {
    Reader()
  }
  public nonisolated func writer(configuration: sending WriteConfiguration) -> sending Writer {
    packageWriter
  }
  nonisolated var packageWriter: Writer { Writer(receipts: receipts) }

  public func apply(snapshot: sending Reader.Snapshot, previous: sending Reader.Snapshot?)
    async throws
  {
    guard editingConnection?.canReloadDocument != false else { throw CocoaError(.userCancelled) }
    confirmedWorkspace = snapshot.workspace
    initialURL = snapshot.url
    editingConnection?.documentDidRead(snapshot.workspace, previous: previous?.workspace)
    adoptDocumentURL(snapshot.url)
  }

  public func snapshot(contentType: UTType) async throws -> sending Writer.Snapshot {
    guard Self.readableContentTypes.contains(contentType) else {
      throw CocoaError(.fileWriteUnsupportedScheme)
    }
    guard let editingConnection else {
      throw WorkspaceSaveValidationError(messages: ["The Workspace editor is not connected."])
    }
    return editingConnection.snapshotForSaving()
  }

  // A staged write is accepted only after it matches the formal document package.
  func acceptPersistedWrite() async {
    guard let url = fileURL, !receipts.withLock({ $0.isEmpty }) else { return }
    do {
      let read: WorkspaceV4Bundle
      if let configuration {
        read = try await Self.readWorkspace(at: url, coordinator: configuration.makeFileCoordinator())
      } else {
        read = try await Self.readWorkspace(at: url, coordinator: NSFileCoordinator())
      }
      guard let receipt = receipts.withLock({ values -> WriteReceipt? in
        guard let index = values.lastIndex(where: { $0.saved == read }) else { return nil }
        let value = values[index]
        values.removeFirst(index + 1)
        return value
      }) else { return }
      confirmedWorkspace = receipt.saved
      editingConnection?.documentDidSave(receipt)
    } catch { editingConnection?.documentDidFail(error) }
  }

  @concurrent private static func readWorkspace(
    at url: URL, coordinator: sending NSFileCoordinator
  ) async throws -> WorkspaceV4Bundle {
    var coordinationError: NSError?
    var result: Result<WorkspaceV4Bundle, Error>?
    coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
      result = Result { try WorkspaceBundleReaderV4(at: source).read() }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw CocoaError(.fileReadUnknown) }
    return try result.get()
  }

  struct WriteReceipt: Sendable {
    let original: Writer.Snapshot
    let saved: WorkspaceV4Bundle
  }

  public struct Reader: DocumentReader {
    public struct Snapshot: Sendable {
      let url: URL
      let workspace: WorkspaceV4Bundle
    }
    @concurrent public func read(from source: sending URL, progress: consuming Subprogress)
      async throws -> sending Snapshot
    {
      let progress = progress.start(totalCount: 1)
      let workspace = try WorkspaceBundleReaderV4(at: source).read()
      try WorkspaceV4IntegrityValidator.validate(workspace)
      progress.complete(count: 1)
      return Snapshot(url: source, workspace: workspace)
    }
  }

  public struct Writer: DocumentWriter {
    let receipts: OSAllocatedUnfairLock<[WriteReceipt]>
    public struct Snapshot: Sendable, Equatable {
      let workspace: WorkspaceV4Bundle
      let modelURLs: [Int64: URL?]
    }
    @concurrent public func write(
      snapshot: sending Snapshot, to destination: sending URL,
      previous: sending Snapshot?, progress: consuming Subprogress
    ) async throws {
      let progress = progress.start(totalCount: 1)
      let saved = try WorkspaceModelFiles.preparedForSaving(
        snapshot.workspace, modelURLs: snapshot.modelURLs)
      let issues = WorkspaceV4IntegrityValidator.validationIssues(in: saved)
      guard issues.isEmpty else {
        throw WorkspaceSaveValidationError(
          messages: issues.map { "\($0.context): \($0.error.localizedDescription)" })
      }
      try WorkspaceDocumentPackage.write(saved, to: destination, createsPackage: true)
      let receipt = WriteReceipt(original: snapshot, saved: saved)
      receipts.withLock { $0.append(receipt) }
      progress.complete(count: 1)
    }
  }
}
