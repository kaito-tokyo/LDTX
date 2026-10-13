// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
public final class WorkspaceDocument: WorkspaceDocumentContext {
  public let stateService: WorkspaceStateService
  public private(set) var workspaceSnapshot: WorkspaceV4Bundle?
  private let configuration: URLDocumentConfiguration?
  private(set) var readGeneration = 0
  public var fileURL: URL? { configuration?.fileURL }
  public var lastContentModificationDate: Date? { configuration?.lastContentModificationDate }
  public var runtimeWorkspace: WorkspaceV4Bundle? { workspaceSnapshot }

  public init(configuration: URLDocumentConfiguration? = nil) {
    self.configuration = configuration
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.displayName = "Untitled"
    stateService = WorkspaceStateService(definition: definition)
    stateService.externalID = WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased()
    stateService.preferencesExternalID = WorkspaceBundleWriterV4.makeExternalID().uuidString
      .lowercased()
    stateService.outputSettingsExternalID = WorkspaceBundleWriterV4.makeExternalID().uuidString
      .lowercased()
    stateService.localStateURL = configuration?.fileURL
  }

  @MainActor
  private func incrementReadGeneration() {
    readGeneration += 1
  }
}

extension WorkspaceDocument: ReadableDocument {
  public nonisolated static let readableContentTypes = [
    UTType(exportedAs: "tokyo.kaito.ldtx.workspace", conformingTo: .package)
  ]

  public struct Reader: DocumentReader {
    @concurrent
    public func read(from source: sending URL, progress: consuming Subprogress) async throws
      -> sending Snapshot
    {
      let workspace = try WorkspaceBundleReaderV4(at: source).read()
      try WorkspaceV4IntegrityValidator.validate(workspace)
      return workspace
    }

    public typealias Snapshot = WorkspaceV4Bundle
  }

  public nonisolated func reader(configuration: sending ReadConfiguration) -> sending Reader {
    Reader()
  }

  public func apply(snapshot: sending Reader.Snapshot, previous: sending Reader.Snapshot?)
    async throws
  {
    workspaceSnapshot = snapshot
    incrementReadGeneration()
  }
}

extension WorkspaceDocument: WritableDocument {
  public struct Writer: DocumentWriter {
    public typealias Snapshot = WorkspaceV4Bundle

    @concurrent public func write(
      snapshot: sending Snapshot, to destination: sending URL,
      previous: sending Snapshot?, progress: consuming Subprogress
    ) async throws {
      try WorkspaceBundleWriterV4().write(snapshot, to: destination)
    }
  }

  public nonisolated func writer(configuration: sending WriteConfiguration) -> sending Writer {
    Writer()
  }

  public func snapshot(contentType: UTType) async throws -> sending Writer.Snapshot {
    guard Self.writableContentTypes.contains(contentType) else {
      throw CocoaError(.fileWriteUnsupportedScheme)
    }
    let snapshot = stateService.editingWorkspace
    workspaceSnapshot = snapshot
    return snapshot
  }
}

extension WorkspaceDocument: Document {}
