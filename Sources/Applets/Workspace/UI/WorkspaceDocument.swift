// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXProgramRuntime
import LDTXProtos
import LDTXProtosMacOSExtra
import LDTXWorkspaceAppletModel
import LDTXWorkspaceBundleFormat
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
public final class WorkspaceDocument: WorkspaceDocumentContext {
  public let runtimeID = UUID()
  @ObservationIgnored private var onRelease: (@MainActor (UUID) -> Void)?
  private let configuration: URLDocumentConfiguration?
  public private(set) var workspace: WorkspaceV4Bundle
  /// Last content read from the canonical package, never a pre-write capture.
  public private(set) var workspaceSnapshot: WorkspaceV4Bundle?
  public var fileURL: URL? { configuration?.fileURL }
  public var lastContentModificationDate: Date? { configuration?.lastContentModificationDate }
  public var runtimeWorkspace: WorkspaceV4Bundle? { workspaceSnapshot }
  public var localStateURL: URL?
  // Compatibility for scene/controller clients: this is the Document itself.
  public var stateService: WorkspaceDocument { self }
  public var editingWorkspace: WorkspaceV4Bundle { workspace }

  public var workspaceDefinition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 { workspace.definition }
  public var workspacePreferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 {
    workspace.preferences
  }
  public var workspaceOutputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4 {
    workspace.outputSettings
  }
  public var visionModels: [Int64: URL] { workspace.visionModels }
  public var externalID: String? { workspace.definitionExternalID }
  public var preferencesExternalID: String? { workspace.preferencesExternalID }
  public var outputSettingsExternalID: String? { workspace.outputSettingsExternalID }
  public var selectedAudioMix: ProgramAudioPeakMeter.Master = .landscape

  public var inspectorSelector: WorkspaceInspectorSelector?
  public var isInspectorVisible = true
  public var isSidebarVisible = true

  public var minimumWindowWidth: CGFloat {
    480 + (isSidebarVisible ? 201 : 0) + (isInspectorVisible ? 241 : 0)
  }

  public var isClosed = false
  public var isInferring = false
  public var operationErrors: [NSError] = []

  public var isOutputActive = false
  public var recordingState: WorkspaceRecordingState = .idle
  public var isLocalRecording = false
  public var outputFailureMessage: String?
  public var visionResults: [Int64: String] = [:]
  public var visionFailureMessages: [Int64: String] = [:]
  public var modelPreparationGeneration: UInt64 = 0

  /// One logical user operation, including changes spanning multiple fields.
  public func editWorkspace(
    undoManager: UndoManager?, _ edit: (inout WorkspaceV4Bundle) throws -> Void
  ) rethrows {
    var next = workspace
    try edit(&next)
    replaceEditingWorkspace(next, undoManager: undoManager)
  }

  public func replaceEditingWorkspace(_ next: WorkspaceV4Bundle, undoManager: UndoManager?) {
    guard next != workspace else { return }
    let previous = workspace
    workspace = next
    undoManager?.registerUndo(withTarget: self) { [weak undoManager] document in
      MainActor.assumeIsolated {
        document.replaceEditingWorkspace(previous, undoManager: undoManager)
      }
    }
    undoManager?.setActionName(String(localized: "Edit Workspace"))
  }

  /// UI bindings explicitly enter the same synchronous document edit operation.
  public func editingBinding<Value>(
    _ keyPath: WritableKeyPath<WorkspaceV4Bundle, Value>, undoManager: UndoManager?
  )
    -> Binding<Value>
  {
    Binding(
      get: { self.workspace[keyPath: keyPath] },
      set: { value in self.editWorkspace(undoManager: undoManager) { $0[keyPath: keyPath] = value }
      })
  }

  public func confirmPersistedWorkspace(_ value: WorkspaceV4Bundle) {
    guard workspaceSnapshot != value else { return }
    workspaceSnapshot = value
  }

  public func setVisionModelURL(_ url: URL?, for visionID: Int64, undoManager: UndoManager?) {
    editWorkspace(undoManager: undoManager) { workspace in
      guard
        let index = workspace.definition.visions.firstIndex(where: { $0.internalID == visionID }),
        case .ldtxSceneDetectorVision(var vision) = workspace.definition.visions[index].vision
      else { return }
      if let url {
        guard workspace.visionModels[vision.modelInternalID] != url else { return }
        let resourceIDs = Set(workspace.definition.audioDevices.map(\.internalID))
          .union(workspace.definition.videoComponents.compactMap(\.internalID))
          .union(workspace.definition.visions.compactMap(\.internalID))
          .union(workspace.definition.programs.map(\.internalID))
        var id: Int64
        repeat {
          id = WorkspaceResourceFactory.nextInternalID()
        } while workspace.visionModels[id] != nil || resourceIDs.contains(id)
        workspace.visionModels[id] = url
        vision.modelInternalID = id
      } else {
        vision.modelInternalID = 0
      }
      workspace.definition.visions[index].vision = .ldtxSceneDetectorVision(vision)
    }
  }

  public init(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 = .init(),
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 = .init(),
    inspectorSelector: WorkspaceInspectorSelector? = nil,
    isOutputActive: Bool = false,
    isLocalRecording: Bool = false,
    outputFailureMessage: String? = nil,
    outputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4 = .init(),
    configuration: URLDocumentConfiguration? = nil,
    onRelease: (@MainActor (UUID) -> Void)? = nil
  ) {
    var definition = definition
    if definition.displayName.isEmpty { definition.displayName = "Untitled" }
    self.workspace = WorkspaceV4Bundle(
      definitionExternalID: WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased(),
      preferencesExternalID: WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased(),
      definition: definition, preferences: preferences,
      outputSettingsExternalID: WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased(),
      outputSettings: outputSettings)
    self.configuration = configuration
    self.onRelease = onRelease
    self.localStateURL = configuration?.fileURL
    self.inspectorSelector = inspectorSelector
    self.isOutputActive = isOutputActive
    self.isLocalRecording = isLocalRecording
    self.outputFailureMessage = outputFailureMessage
  }
  isolated deinit {
    onRelease?(runtimeID)
  }

}

extension WorkspaceDocument: ReadableDocument {
  public nonisolated static let readableContentTypes = [
    UTType(exportedAs: "tokyo.kaito.ldtx.workspace", conformingTo: .package)
  ]

  public struct Reader: DocumentReader {
    public init() {}

    @concurrent
    public func read(from source: sending URL, progress: consuming Subprogress) async throws
      -> sending Snapshot
    {
      let workspace = try WorkspaceBundleReaderV4(at: source).read()
      try workspace.definition.validateRichTextDocuments()
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
    try snapshot.definition.validateRichTextDocuments()
    workspaceSnapshot = snapshot
    workspace = snapshot
  }
}

extension WorkspaceDocument: WritableDocument {
  public struct Writer: DocumentWriter {
    public init() {}

    public typealias Snapshot = WorkspaceV4Bundle

    @concurrent public func write(
      snapshot: sending Snapshot, to destination: sending URL,
      previous: sending Snapshot?, progress: consuming Subprogress
    ) async throws {
      try snapshot.definition.validateRichTextDocuments()
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
    return workspace
  }
}

extension WorkspaceDocument: Document {}
