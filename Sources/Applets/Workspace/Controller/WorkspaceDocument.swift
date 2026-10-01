// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import os

@MainActor
@objc(WorkspaceDocument)
public final class WorkspaceDocument: NSDocument {
  public let uiState = WorkspaceUIState(definition: .init(), preferences: .init())
  public var appletData = WorkspaceAppletData()
  private let transientURL = URL(string: "ldtx-untitled://workspace/\(UUID().uuidString)")!
  private struct SaveSnapshot: Sendable {
    let workspace: WorkspaceV4Bundle
    let sourceURL: URL?
  }
  private nonisolated let writingSnapshot = OSAllocatedUnfairLock<SaveSnapshot?>(initialState: nil)
  private var sourceContentsURL: URL?
  private var definitionExternalID: String? = WorkspaceBundleWriterV4.makeExternalID().uuidString
    .lowercased()
  private var preferencesExternalID: String? = WorkspaceBundleWriterV4.makeExternalID().uuidString
    .lowercased()
  private var isReading = false
  private var outputDefinition: WorkspaceUIState.WorkspaceDefinition?
  private var closeCallbacks: [WorkspaceCloseCallback] = []
  private var saveCallbacks: [WorkspaceSaveCallback] = []
  private var hasShutDown = false
  private var didReportShutdownFailure = false
  private var heldLock: WorkspaceLock?
  private let lockService = WorkspaceLockService()

  public lazy var persistenceCoordinator = WorkspaceV4PersistenceCoordinator(
    workspaceSnapshot: { [unowned self] in snapshot },
    workspaceIsDirty: { [unowned self] in isDocumentEdited },
    replaceWorkspace: { [unowned self] workspace in try replaceContents(workspace) },
    markWorkspaceSaved: {}, url: fileURL)

  private var snapshot: WorkspaceV4Bundle {
    WorkspaceV4Bundle(
      definitionExternalID: definitionExternalID,
      preferencesExternalID: preferencesExternalID,
      definition: uiState.definition, preferences: uiState.preferences)
  }

  public override init() {
    super.init()
    fileType = "tokyo.kaito.ldtx.workspace"
    uiState.definition.displayName = "Untitled"
    uiState.localStateURL = transientURL
    uiState.documentContentsDidChange = { [weak self] in
      guard let self, !isReading else { return }
      if let outputDefinition, uiState.definition != outputDefinition {
        isReading = true
        uiState.definition = outputDefinition
        isReading = false
        return
      }
      updateChangeCount(.changeDone)
    }
    uiState.documentOutputStateDidChange = { [weak self] in
      guard let self else { return }
      outputDefinition = uiState.isOutputActive ? uiState.definition : nil
      Self.updateRecordingDockBadge()
    }
  }

  static func updateRecordingDockBadge() {
    let isOutputActive = NSDocumentController.shared.documents.contains {
      ($0 as? WorkspaceDocument)?.uiState.isOutputActive == true
    }
    NSApplication.shared.dockTile.badgeLabel = isOutputActive ? "REC" : nil
  }

  public override class var autosavesInPlace: Bool { true }

  public override func makeWindowControllers() {
    guard windowControllers.isEmpty else { return }
    appletData.registerTransientState(at: transientURL)
    let windowController = WorkspaceWindowController(
      uiState: uiState, persistenceCoordinator: persistenceCoordinator,
      appletData: appletData)
    addWindowController(windowController)
  }

  public override nonisolated func read(from url: URL, ofType typeName: String) throws {
    try MainActor.assumeIsolated {
      guard !uiState.isOutputActive else { throw CocoaError(.userCancelled) }
      let workspace = try WorkspaceBundleReaderV4(at: url).read()
      try WorkspaceV4IntegrityValidator.validate(workspace)
      try replaceContents(workspace)
      sourceContentsURL = url
    }
  }

  private func replaceContents(_ workspace: WorkspaceV4Bundle) throws {
    isReading = true
    defer { isReading = false }
    uiState.definition = workspace.definition
    uiState.preferences = workspace.preferences
    definitionExternalID = workspace.definitionExternalID
    preferencesExternalID = workspace.preferencesExternalID
  }

  public override func canAsynchronouslyWrite(
    to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
  ) -> Bool {
    let contents = SaveSnapshot(workspace: snapshot, sourceURL: sourceContentsURL)
    writingSnapshot.withLock { $0 = contents }
    return true
  }

  public override nonisolated func fileWrapper(ofType typeName: String) throws -> FileWrapper {
    let contents: SaveSnapshot
    if Thread.isMainThread {
      // Duplicate uses the synchronous safe-write path rather than save(to:...).
      contents = MainActor.assumeIsolated {
        SaveSnapshot(workspace: snapshot, sourceURL: sourceContentsURL)
      }
    } else {
      guard let saved = writingSnapshot.withLock({ $0 }) else {
        throw CocoaError(.fileWriteUnknown)
      }
      contents = saved
    }
    let wrapper = try WorkspaceDocumentPackage.fileWrapper(
      for: contents.workspace, preserving: contents.sourceURL)
    unblockUserInteraction()
    return wrapper
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
    let adoptsURL =
      saveOperation == .saveOperation || saveOperation == .saveAsOperation
      || saveOperation == .autosaveInPlaceOperation
    if uiState.isOutputActive && saveOperation == .saveAsOperation {
      completionHandler(CocoaError(.userCancelled))
      return
    }
    var destinationLock: WorkspaceLock?
    do {
      if adoptsURL && (heldLock == nil || fileURL?.standardizedFileURL != url.standardizedFileURL) {
        destinationLock = try lockService.acquire(at: url, createsPackageDirectory: true)
      }
    } catch {
      completionHandler(error)
      return
    }
    let acquiredLock = destinationLock
    super.save(to: url, ofType: typeName, for: saveOperation) { [self] error in
      if let error {
        if let acquiredLock { releaseFailedDestination(acquiredLock, at: url) }
        completionHandler(error)
        return
      }
      if adoptsURL {
        if let acquiredLock {
          if let heldLock { lockService.release(heldLock) }
          heldLock = acquiredLock
        }
        adoptDocumentURL(url)
      }
      completionHandler(nil)
    }
  }

  private func releaseFailedDestination(_ lock: WorkspaceLock, at url: URL) {
    lockService.release(lock)
    if lock.createdPackageDirectory,
      let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
      contents.isEmpty
    {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func adoptDocumentURL(_ url: URL) {
    sourceContentsURL = url
    if let previous = uiState.localStateURL, previous != url {
      appletData.copyState(from: previous, to: url)
    }
    uiState.localStateURL = url
    persistenceCoordinator.setDocumentURL(url)
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
    guard !uiState.isOutputActive else {
      completionHandler?(CocoaError(.userCancelled))
      return
    }
    guard fileURL != nil else {
      super.move(to: url, completionHandler: completionHandler)
      return
    }
    if fileURL?.standardizedFileURL == url.standardizedFileURL {
      super.move(to: url, completionHandler: completionHandler)
      return
    }
    let destinationLock: WorkspaceLock
    do { destinationLock = try lockService.acquire(at: url, createsPackageDirectory: true) } catch {
      completionHandler?(error)
      return
    }
    super.move(to: url) { [self] error in
      if let error {
        releaseFailedDestination(destinationLock, at: url)
        completionHandler?(error)
        return
      }
      if let heldLock { lockService.release(heldLock) }
      heldLock = destinationLock
      adoptDocumentURL(url)
      completionHandler?(nil)
    }
  }

  /// Called by the document controller once AppKit has established the formal URL.
  public func acquirePackageLock() throws {
    guard heldLock == nil, let fileURL else { return }
    heldLock = try lockService.acquire(at: fileURL)
    uiState.localStateURL = fileURL
    persistenceCoordinator.setDocumentURL(fileURL)
  }

  public func saveBeforeOutput() async throws {
    try await withCheckedThrowingContinuation { continuation in
      let callback = WorkspaceSaveCallback { [weak self] callback, success in
        self?.saveCallbacks.removeAll { $0 === callback }
        if success {
          continuation.resume()
        } else {
          continuation.resume(throwing: CocoaError(.userCancelled))
        }
      }
      saveCallbacks.append(callback)
      save(
        withDelegate: callback,
        didSave: #selector(WorkspaceSaveCallback.saved(_:didSave:contextInfo:)), contextInfo: nil)
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
    if let heldLock {
      lockService.release(heldLock)
      self.heldLock = nil
    }
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
    if uiState.isOutputActive
      && (item.action == #selector(saveAs(_:)) || item.action == #selector(revertToSaved(_:))
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
