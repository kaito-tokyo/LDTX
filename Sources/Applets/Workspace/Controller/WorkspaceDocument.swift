// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXProtos
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import os

@MainActor
@objc(WorkspaceDocument)
public final class WorkspaceDocument: NSDocument {
  public let storeService = WorkspaceStoreService(definition: .init(), preferences: .init())
  public let appletData = WorkspaceAppletData.shared
  private let transientURL = URL(string: "ldtx-untitled://workspace/\(UUID().uuidString)")!
  private struct SaveSnapshot: Sendable {
    let workspace: WorkspaceV4Bundle
    let formalURL: URL?
  }
  private nonisolated let writingSnapshot = OSAllocatedUnfairLock<SaveSnapshot?>(initialState: nil)
  private var preferencesExternalID: String? = WorkspaceBundleWriterV4.makeExternalID().uuidString
    .lowercased()
  private var isReading = false
  private var outputDefinition: WorkspaceStoreService.WorkspaceDefinition?
  private var closeCallbacks: [WorkspaceCloseCallback] = []
  private var saveCallbacks: [WorkspaceSaveCallback] = []
  private var hasShutDown = false
  private var didReportShutdownFailure = false

  public lazy var persistenceCoordinator = WorkspaceV4PersistenceCoordinator(
    workspaceSnapshot: { [unowned self] in snapshot },
    replaceWorkspace: { [unowned self] workspace in try replaceContents(workspace) },
    url: fileURL)

  private var snapshot: WorkspaceV4Bundle {
    WorkspaceV4Bundle(
      definitionExternalID: storeService.externalID,
      preferencesExternalID: preferencesExternalID,
      definition: storeService.definition, preferences: storeService.preferences)
  }

  public override init() {
    super.init()
    fileType = "tokyo.kaito.ldtx.workspace"
    storeService.externalID = WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased()
    storeService.definition.displayName = "Untitled"
    storeService.localStateURL = transientURL
    storeService.documentContentsDidChange = { [weak self] in
      guard let self, !isReading else { return }
      if let outputDefinition, storeService.definition != outputDefinition {
        guard Self.isVideoLayerReordering(storeService.definition, of: outputDefinition) else {
          isReading = true
          storeService.definition = outputDefinition
          isReading = false
          return
        }
        self.outputDefinition = storeService.definition
      }
      updateChangeCount(.changeDone)
    }
    storeService.documentOutputStateDidChange = { [weak self] in
      guard let self else { return }
      outputDefinition = storeService.isOutputActive ? storeService.definition : nil
      Self.updateRecordingDockBadge()
    }
  }

  private static func isVideoLayerReordering(
    _ candidate: WorkspaceStoreService.WorkspaceDefinition,
    of baseline: WorkspaceStoreService.WorkspaceDefinition
  ) -> Bool {
    guard candidate.programs.count == baseline.programs.count else { return false }
    var normalized = candidate
    for index in baseline.programs.indices {
      let before = baseline.programs[index]
      let after = candidate.programs[index]
      guard
        before.landscapeVideoLayerInternalIds.sorted()
          == after.landscapeVideoLayerInternalIds.sorted(),
        before.portraitVideoLayerInternalIds.sorted()
          == after.portraitVideoLayerInternalIds.sorted()
      else { return false }
      normalized.programs[index].landscapeVideoLayerInternalIds =
        before.landscapeVideoLayerInternalIds
      normalized.programs[index].portraitVideoLayerInternalIds =
        before.portraitVideoLayerInternalIds
    }
    return normalized == baseline
  }

  /// Restores only the formal package; legacy recovery contents are not adopted.
  public convenience init(
    for urlOrNil: URL?, withContentsOf contentsURL: URL, ofType typeName: String
  ) throws {
    guard let urlOrNil else { throw CocoaError(.fileReadNoSuchFile) }
    try self.init(contentsOf: urlOrNil, ofType: typeName)
  }

  static func updateRecordingDockBadge() {
    let isOutputActive = NSDocumentController.shared.documents.contains {
      ($0 as? WorkspaceDocument)?.storeService.isOutputActive == true
    }
    NSApplication.shared.dockTile.badgeLabel = isOutputActive ? "REC" : nil
  }

  public override nonisolated class var autosavesInPlace: Bool { false }
  public override nonisolated class var preservesVersions: Bool { false }
  public override nonisolated var autosavingFileType: String? { nil }

  public override func makeWindowControllers() {
    guard windowControllers.isEmpty else { return }
    appletData.registerTransientState(at: transientURL)
    let windowController = WorkspaceWindowController(
      storeService: storeService, persistenceCoordinator: persistenceCoordinator,
      appletData: appletData, documentReference: DocumentReference(self))
    addWindowController(windowController)
  }

  public override nonisolated func read(from url: URL, ofType typeName: String) throws {
    try MainActor.assumeIsolated {
      guard !storeService.isOutputActive else { throw CocoaError(.userCancelled) }
      let workspace = try WorkspaceBundleReaderV4(at: url).read()
      try WorkspaceV4IntegrityValidator.validate(workspace)
      try replaceContents(workspace)
      storeService.localStateURL = url
      persistenceCoordinator.setDocumentURL(url)
    }
  }

  private func replaceContents(_ workspace: WorkspaceV4Bundle) throws {
    isReading = true
    defer { isReading = false }
    storeService.definition = workspace.definition
    storeService.preferences = workspace.preferences
    storeService.externalID = workspace.definitionExternalID
    preferencesExternalID = workspace.preferencesExternalID
  }

  private var writingChangeCountToken: (token: Any, operation: NSDocument.SaveOperationType)?

  public override func updateChangeCount(_ change: NSDocument.ChangeType) {
    // Non-autosaving documents clear all changes after a successful asynchronous save.
    // Apply the snapshot's AppKit token instead so later edits remain unsaved.
    if change == .changeCleared, let token = writingChangeCountToken {
      super.updateChangeCount(withToken: token.token, for: token.operation)
    } else {
      super.updateChangeCount(change)
    }
  }

  public override func canAsynchronouslyWrite(
    to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
  ) -> Bool {
    writingChangeCountToken = (super.changeCountToken(for: saveOperation), saveOperation)
    let contents = SaveSnapshot(
      workspace: snapshot, formalURL: fileURL)
    writingSnapshot.withLock { $0 = contents }
    return true
  }

  // Partial writes cannot provide AppKit with a renamed whole-package backup.
  public override nonisolated var backupFileURL: URL? { nil }

  // Tests can pause I/O after AppKit interaction has been released.
  nonisolated let writeProbe = OSAllocatedUnfairLock<(@Sendable () throws -> Void)?>(
    initialState: nil)

  public override nonisolated func writeSafely(
    to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
  ) throws {
    let contents: SaveSnapshot
    if Thread.isMainThread {
      contents = MainActor.assumeIsolated {
        SaveSnapshot(workspace: snapshot, formalURL: fileURL)
      }
    } else {
      guard let saved = writingSnapshot.withLock({ $0 }) else {
        throw CocoaError(.fileWriteUnknown)
      }
      contents = saved
    }
    guard typeName == "tokyo.kaito.ldtx.workspace" else {
      throw CocoaError(.fileWriteUnsupportedScheme)
    }
    let createsPackage: Bool
    switch saveOperation {
    case .saveOperation:
      guard url.standardizedFileURL == contents.formalURL?.standardizedFileURL else {
        throw CocoaError(.featureUnsupported)
      }
      createsPackage = false
    case .saveAsOperation:
      guard contents.formalURL == nil else { throw CocoaError(.featureUnsupported) }
      createsPackage = true
    default:
      throw CocoaError(.featureUnsupported)
    }
    unblockUserInteraction()
    try writeProbe.withLock { $0 }?()
    let coordinator = NSFileCoordinator(filePresenter: self)
    var coordinationError: NSError?
    var writeError: Error?
    coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) {
      destination in
      do {
        try WorkspaceDocumentPackage.write(
          contents.workspace, to: destination, createsPackage: createsPackage)
      } catch { writeError = error }
    }
    if let error = coordinationError ?? writeError as NSError? {
      Logger(subsystem: "tokyo.kaito.ldtx", category: "WorkspaceDocument").error(
        "Saving Workspace failed: \(error.localizedDescription, privacy: .public)")
      throw error
    }
  }

  public override func save(
    to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
    completionHandler: @escaping (Error?) -> Void
  ) {
    performActivity(withSynchronousWaiting: false) { [self] activityCompletion in
      continueActivity {
        saveUsingAppKit(to: url, ofType: typeName, for: saveOperation) { error in
          activityCompletion()
          completionHandler(error)
        }
      }
    }
  }

  private func saveUsingAppKit(
    to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard
      (saveOperation == .saveAsOperation && fileURL == nil)
        || (saveOperation == .saveOperation
          && fileURL?.standardizedFileURL == url.standardizedFileURL)
    else {
      completionHandler(CocoaError(.featureUnsupported))
      return
    }
    let initialName = storeService.definition.displayName
    let derivesInitialName = fileURL == nil && initialName == "Untitled"
    let destinationName = url.deletingPathExtension().lastPathComponent
    if derivesInitialName { storeService.definition.displayName = destinationName }
    super.save(to: url, ofType: typeName, for: saveOperation) { [self] error in
      writingChangeCountToken = nil
      if let error {
        if derivesInitialName && fileURL == nil
          && storeService.definition.displayName == destinationName
        {
          storeService.definition.displayName = initialName
        }
        completionHandler(error)
        return
      }
      adoptDocumentURL(url)
      completionHandler(nil)
    }
  }

  private func adoptDocumentURL(_ url: URL) {
    if let previous = storeService.localStateURL, previous != url {
      appletData.copyState(from: previous, to: url)
    }
    storeService.localStateURL = url
    persistenceCoordinator.setDocumentURL(url)
  }

  public override nonisolated func presentedItemDidMove(to newURL: URL) {
    super.presentedItemDidMove(to: newURL)
    Task { @MainActor [self] in
      guard !hasShutDown,
        storeService.localStateURL?.standardizedFileURL != newURL.standardizedFileURL
      else { return }
      adoptDocumentURL(newURL)
    }
  }

  public override func move(to url: URL, completionHandler: ((Error?) -> Void)? = nil) {
    performActivity(withSynchronousWaiting: false) { [self] activityCompletion in
      continueActivity {
        moveUsingAppKit(to: url) { error in
          activityCompletion()
          completionHandler?(error)
        }
      }
    }
  }

  private func moveUsingAppKit(to url: URL, completionHandler: ((Error?) -> Void)?) {
    guard !storeService.isOutputActive else {
      completionHandler?(CocoaError(.userCancelled))
      return
    }
    super.move(to: url) { [self] error in
      if let error {
        completionHandler?(error)
        return
      }
      adoptDocumentURL(url)
      completionHandler?(nil)
    }
  }

  public func saveAfterCreation() {
    let callback = WorkspaceSaveCallback { [weak self] callback, success in
      guard let self else { return }
      saveCallbacks.removeAll { $0 === callback }
      finishCreation(success: success)
    }
    saveCallbacks.append(callback)
    save(
      withDelegate: callback,
      didSave: #selector(WorkspaceSaveCallback.saved(_:didSave:contextInfo:)), contextInfo: nil)
  }

  // Also exercised without a modal panel by the document system tests.
  func finishCreation(success: Bool) {
    if success {
      makeWindowControllers()
      showWindows()
    } else {
      close()
    }
  }

  public override func canClose(
    withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
    contextInfo: UnsafeMutableRawPointer?
  ) {
    let callback = WorkspaceCloseCallback(
      delegate: delegate as AnyObject, selector: shouldCloseSelector, context: contextInfo
    ) { [weak self] callback in self?.closeCallbacks.removeAll { $0 === callback } }
    closeCallbacks.append(callback)
    super.canClose(
      withDelegate: callback,
      shouldClose: #selector(WorkspaceCloseCallback.reviewed(_:shouldClose:contextInfo:)),
      contextInfo: nil)
  }

  public override func close() {
    if hasShutDown || windowControllers.isEmpty {
      finishClose()
      return
    }
    // Direct programmatic closes must also finish resource teardown.
    Task { @MainActor in
      await shutdown()
      finishClose()
    }
  }

  private func finishClose() {
    appletData.removeTransientState(at: transientURL)
    super.close()
    Self.updateRecordingDockBadge()
  }

  public func shutdown() async {
    for windowController in windowControllers {
      guard let workspaceWindowController = windowController as? WorkspaceWindowController else {
        continue
      }
      await workspaceWindowController.shutdown()
      if let message = workspaceWindowController.shutdownFailureMessage, !didReportShutdownFailure {
        didReportShutdownFailure = true
        presentError(
          NSError(
            domain: "tokyo.kaito.ldtx.WorkspaceShutdown", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]))
      }
    }
    hasShutDown = true
  }

  public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(duplicate(_:)) || item.action == #selector(saveAs(_:))
      || item.action == #selector(saveTo(_:))
    {
      return false
    }
    if storeService.isOutputActive
      && (item.action == #selector(revertToSaved(_:))
        || item.action == #selector(move(_:)) || item.action == #selector(rename(_:)))
    {
      return false
    }
    return super.validateUserInterfaceItem(item)
  }
}

@MainActor
private final class WorkspaceSaveCallback: NSObject {
  let completion: (WorkspaceSaveCallback, Bool) -> Void
  init(completion: @escaping (WorkspaceSaveCallback, Bool) -> Void) { self.completion = completion }
  @objc func saved(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
    completion(self, didSave)
  }
}

@MainActor
private final class WorkspaceCloseCallback: NSObject {
  let target: AnyObject
  let selector: Selector?
  let context: UnsafeMutableRawPointer?
  let completion: (WorkspaceCloseCallback) -> Void
  init(
    delegate: AnyObject, selector: Selector?, context: UnsafeMutableRawPointer?,
    completion: @escaping (WorkspaceCloseCallback) -> Void
  ) {
    target = delegate
    self.selector = selector
    self.context = context
    self.completion = completion
  }
  @objc func reviewed(
    _ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?
  ) {
    Task { @MainActor in
      if shouldClose { await (document as? WorkspaceDocument)?.shutdown() }
      if let selector, let object = target as? NSObject {
        typealias Callback =
          @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        let callback = unsafeBitCast(object.method(for: selector), to: Callback.self)
        callback(target, selector, document, shouldClose, context)
      }
      completion(self)
    }
  }
}
