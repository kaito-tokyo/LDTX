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
  public let uiState = WorkspaceUIState(definition: .init(), preferences: .init())
  public let appletData = WorkspaceAppletData.shared
  private let transientURL = URL(string: "ldtx-untitled://workspace/\(UUID().uuidString)")!
  private struct SaveSnapshot: Sendable {
    let workspace: WorkspaceV4Bundle
    let sourceURL: URL?
    let formalURL: URL?
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
  private var creationSaveFailed: Bool?
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

  /// Restore through AppKit's ordinary contents initializer, then adopt only the
  /// formal document URL. Recovery contents remain the resource snapshot source.
  public convenience init(
    for urlOrNil: URL?, withContentsOf contentsURL: URL, ofType typeName: String
  ) throws {
    try self.init(contentsOf: contentsURL, ofType: typeName)
    do {
      if urlOrNil?.standardizedFileURL != contentsURL.standardizedFileURL {
        if let heldLock { lockService.release(heldLock) }
        heldLock = nil
        if let urlOrNil { heldLock = try lockService.acquire(at: urlOrNil) }
      }
      fileURL = urlOrNil
      autosavedContentsFileURL = contentsURL
      uiState.localStateURL = urlOrNil ?? transientURL
      persistenceCoordinator.setDocumentURL(urlOrNil)
      if let urlOrNil {
        fileModificationDate = try urlOrNil.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
      }
      if urlOrNil?.standardizedFileURL != contentsURL.standardizedFileURL {
        updateChangeCount(.changeReadOtherContents)
      }
    } catch {
      finishClose()
      throw error
    }
  }

  isolated deinit {
    if let heldLock { lockService.release(heldLock) }
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
      appletData: appletData, documentReference: DocumentReference(self))
    addWindowController(windowController)
  }

  public override nonisolated func read(from url: URL, ofType typeName: String) throws {
    try MainActor.assumeIsolated {
      guard !uiState.isOutputActive else { throw CocoaError(.userCancelled) }
      let acquiredLock = heldLock == nil ? try lockService.acquire(at: url) : nil
      do {
        let workspace = try WorkspaceBundleReaderV4(at: url).read()
        try WorkspaceV4IntegrityValidator.validate(workspace)
        try replaceContents(workspace)
        sourceContentsURL = url
        if let acquiredLock {
          heldLock = acquiredLock
          uiState.localStateURL = url
          persistenceCoordinator.setDocumentURL(url)
        }
      } catch {
        if let acquiredLock { lockService.release(acquiredLock) }
        throw error
      }
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
    let contents = SaveSnapshot(
      workspace: snapshot, sourceURL: sourceContentsURL, formalURL: fileURL)
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
        SaveSnapshot(workspace: snapshot, sourceURL: sourceContentsURL, formalURL: fileURL)
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
    case .saveOperation, .autosaveInPlaceOperation:
      guard url.standardizedFileURL == contents.formalURL?.standardizedFileURL else {
        throw CocoaError(.featureUnsupported)
      }
      createsPackage = false
    case .saveAsOperation:
      guard contents.formalURL == nil else { throw CocoaError(.featureUnsupported) }
      createsPackage = true
    case .autosaveElsewhereOperation, .autosaveAsOperation:
      createsPackage = true
    default:
      throw CocoaError(.featureUnsupported)
    }
    unblockUserInteraction()
    try writeProbe.withLock { $0 }?()
    let coordinator = NSFileCoordinator(filePresenter: self)
    var coordinationError: NSError?
    var writeError: Error?
    func write(to destination: URL, preserving source: URL?) {
      do {
        try WorkspaceDocumentPackage.write(
          contents.workspace, to: destination, preserving: source, createsPackage: createsPackage)
      } catch { writeError = error }
    }
    if createsPackage, let source = contents.sourceURL,
      source.standardizedFileURL != url.standardizedFileURL
    {
      coordinator.coordinate(
        readingItemAt: source, options: .withoutChanges,
        writingItemAt: url, options: .forMerging, error: &coordinationError
      ) { source, destination in
        write(to: destination, preserving: source)
      }
    } else {
      coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) {
        write(to: $0, preserving: nil)
      }
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
          if error != nil, saveOperation == .saveAsOperation, self.creationSaveFailed != nil {
            self.creationSaveFailed = true
          }
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
    if saveOperation == .saveToOperation
      || (saveOperation == .saveAsOperation && fileURL != nil)
      || ((saveOperation == .saveOperation || saveOperation == .autosaveInPlaceOperation)
        && fileURL?.standardizedFileURL != url.standardizedFileURL)
    {
      completionHandler(CocoaError(.featureUnsupported))
      return
    }
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
    let initialName = uiState.definition.displayName
    let derivesInitialName = adoptsURL && fileURL == nil && initialName == "Untitled"
    let destinationName = url.deletingPathExtension().lastPathComponent
    if derivesInitialName { uiState.definition.displayName = destinationName }
    let acquiredLock = destinationLock
    super.save(to: url, ofType: typeName, for: saveOperation) { [self] error in
      if let error {
        if derivesInitialName && fileURL == nil && uiState.definition.displayName == destinationName
        {
          uiState.definition.displayName = initialName
        }
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

  public override nonisolated func presentedItemDidMove(to newURL: URL) {
    super.presentedItemDidMove(to: newURL)
    Task { @MainActor [self] in
      guard !hasShutDown, sourceContentsURL?.standardizedFileURL != newURL.standardizedFileURL
      else { return }
      do {
        let destinationLock = try lockService.acquire(at: newURL)
        if let heldLock { lockService.release(heldLock) }
        heldLock = destinationLock
        adoptDocumentURL(newURL)
      } catch {
        if let heldLock { lockService.release(heldLock) }
        heldLock = nil
        adoptDocumentURL(newURL)
        Logger(subsystem: "tokyo.kaito.ldtx", category: "WorkspaceDocument").error(
          "Rebinding moved Workspace failed: \(error.localizedDescription, privacy: .public)")
        presentError(error)
      }
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

  public func saveAfterCreation() {
    creationSaveFailed = false
    let callback = WorkspaceSaveCallback { [weak self] callback, success in
      guard let self else { return }
      let failed = creationSaveFailed == true
      creationSaveFailed = nil
      saveCallbacks.removeAll { $0 === callback }
      if !success && !failed { close() }
    }
    saveCallbacks.append(callback)
    save(
      withDelegate: callback,
      didSave: #selector(WorkspaceSaveCallback.saved(_:didSave:contextInfo:)), contextInfo: nil)
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
    if item.action == #selector(duplicate(_:)) || item.action == #selector(saveAs(_:))
      || item.action == #selector(saveTo(_:))
    {
      return false
    }
    if uiState.isOutputActive
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
