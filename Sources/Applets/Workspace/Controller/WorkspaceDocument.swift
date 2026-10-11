// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXProtos
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Observation
import os

@MainActor
@objc(WorkspaceDocument)
public final class WorkspaceDocument: NSDocument {
  public let storeService: WorkspaceStoreService
  public let editingState: WorkspaceEditingState
  public let appletData = WorkspaceAppletData.shared
  private let transientURL = URL(string: "ldtx-untitled://workspace/\(UUID().uuidString)")!
  private struct SaveSnapshot: Sendable {
    let workspace: WorkspaceV4Bundle
    let formalURL: URL?
    let modelURLs: [Int64: URL?]
  }
  private nonisolated let writingSnapshot = OSAllocatedUnfairLock<SaveSnapshot?>(initialState: nil)
  private nonisolated let savedModelSnapshot = OSAllocatedUnfairLock<WorkspaceV4Bundle?>(
    initialState: nil)
  private var preferencesExternalID: String? = WorkspaceBundleWriterV4.makeExternalID().uuidString
    .lowercased()
  private var outputStateObservationTask: Task<Void, Never>?
  private var isReading = false
  private var closeCallbacks: [WorkspaceCloseCallback] = []
  private var saveCallbacks: [WorkspaceSaveCallback] = []
  private var hasShutDown = false
  private var didReportShutdownFailure = false

  public lazy var persistenceCoordinator = WorkspaceV4PersistenceCoordinator(
    workspaceSnapshot: { [unowned self] in snapshot },
    replaceWorkspace: { [unowned self] workspace in try replaceContents(workspace) },
    url: fileURL)

  private var outputSettingsExternalID: String? = WorkspaceBundleWriterV4.makeExternalID()
    .uuidString.lowercased()

  private var snapshot: WorkspaceV4Bundle {
    WorkspaceV4Bundle(
      definitionExternalID: storeService.externalID,
      preferencesExternalID: preferencesExternalID,
      definition: storeService.workspaceDefinition, preferences: storeService.workspacePreferences,
      outputSettingsExternalID: outputSettingsExternalID,
      outputSettings: storeService.workspaceOutputSettings, models: storeService.workspaceModels)
  }

  public override init() {
    let editingState = WorkspaceEditingState()
    self.editingState = editingState
    self.storeService = WorkspaceStoreService(
      definition: .init(), preferences: .init())
    super.init()
    fileType = "tokyo.kaito.ldtx.workspace"
    storeService.externalID = WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased()
    storeService.workspaceDefinition.displayName = "Untitled"
    storeService.localStateURL = transientURL
    observeWorkspaceContents()
    let outputStates = Observations { [storeService] in storeService.isOutputActive }
    outputStateObservationTask = Task { @MainActor [weak self] in
      for await _ in outputStates {
        guard !Task.isCancelled, let self, !self.hasShutDown else { return }
        Self.updateRecordingDockBadge()
      }
    }
  }

  private func observeWorkspaceContents() {
    guard !hasShutDown else { return }
    withObservationTracking {
      _ = storeService.modelURLs
      _ = storeService.workspaceModels
      _ = storeService.workspaceDefinition
      _ = storeService.workspacePreferences
      _ = storeService.workspaceOutputSettings
    } onChange: { [weak self] in
      // The observed Store is MainActor-isolated; its mutations happen here.
      MainActor.assumeIsolated {
        guard let self, !self.hasShutDown else { return }
        if !self.isReading { self.updateChangeCount(.changeDone) }
        self.observeWorkspaceContents()
      }
    }
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
      storeService: storeService, editingState: editingState,
      persistenceCoordinator: persistenceCoordinator,
      appletData: appletData, document: self)
    addWindowController(windowController)
  }

  public override nonisolated func read(from url: URL, ofType typeName: String) throws {
    try MainActor.assumeIsolated {
      guard !storeService.isOutputActive else { throw CocoaError(.userCancelled) }
      let workspace = try WorkspaceBundleReaderV4(at: url).read()
      try WorkspaceV4IntegrityValidator.validate(workspace)
      try replaceContents(workspace)
      storeService.localStateURL = url
      if let externalID = storeService.externalID.flatMap(UUID.init(uuidString:)) {
        appletData.migrateOutputData(from: url, externalID: externalID)
      }
      persistenceCoordinator.setDocumentURL(url)
    }
  }

  private func replaceContents(_ workspace: WorkspaceV4Bundle) throws {
    isReading = true
    defer { isReading = false }
    storeService.modelURLs = [:]
    storeService.workspaceModels = workspace.models
    storeService.workspaceDefinition = workspace.definition
    storeService.workspacePreferences = workspace.preferences
    storeService.workspaceOutputSettings = workspace.outputSettings
    outputSettingsExternalID = workspace.outputSettingsExternalID
    storeService.externalID = workspace.definitionExternalID
    preferencesExternalID = workspace.preferencesExternalID
  }

  private nonisolated static func validateForSaving(_ workspace: WorkspaceV4Bundle) throws {
    let issues = WorkspaceV4IntegrityValidator.validationIssues(in: workspace)
    guard issues.isEmpty else {
      throw WorkspaceSaveValidationError(
        messages: issues.map { "\($0.context): \($0.error.localizedDescription)" })
    }
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
      workspace: snapshot, formalURL: fileURL, modelURLs: storeService.modelURLs)
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
        SaveSnapshot(workspace: snapshot, formalURL: fileURL, modelURLs: storeService.modelURLs)
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
    let savedWorkspace = try WorkspaceModelFiles.preparedForSaving(
      contents.workspace, modelURLs: contents.modelURLs)
    try Self.validateForSaving(savedWorkspace)
    unblockUserInteraction()
    try writeProbe.withLock { $0 }?()
    let coordinator = NSFileCoordinator(filePresenter: self)
    var coordinationError: NSError?
    var writeError: Error?
    coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) {
      destination in
      do {
        try WorkspaceDocumentPackage.write(
          savedWorkspace, to: destination, createsPackage: createsPackage)
      } catch { writeError = error }
    }
    if let error = coordinationError ?? writeError as NSError? {
      Logger(subsystem: "tokyo.kaito.ldtx", category: "WorkspaceDocument").error(
        "Saving Workspace failed: \(error.localizedDescription, privacy: .public)")
      throw error
    }
    savedModelSnapshot.withLock { $0 = savedWorkspace }
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
    let initialName = storeService.workspaceDefinition.displayName
    let derivesInitialName = fileURL == nil && initialName == "Untitled"
    let destinationName = url.deletingPathExtension().lastPathComponent
    if derivesInitialName { storeService.workspaceDefinition.displayName = destinationName }
    do {
      try editingState.validateInspectorEdits()
      try Self.validateForSaving(snapshot)
    } catch {
      if derivesInitialName { storeService.workspaceDefinition.displayName = initialName }
      editingState.reportInputValidationError(error)
      completionHandler(CocoaError(.userCancelled))
      return
    }
    savedModelSnapshot.withLock { $0 = nil }
    super.save(to: url, ofType: typeName, for: saveOperation) { [self] error in
      writingChangeCountToken = nil
      if let error {
        if derivesInitialName && fileURL == nil
          && storeService.workspaceDefinition.displayName == destinationName
        {
          storeService.workspaceDefinition.displayName = initialName
        }
        completionHandler(error)
        return
      }
      if let saved = savedModelSnapshot.withLock({ $0 }),
        let original = writingSnapshot.withLock({ $0 })
      {
        isReading = true
        for wrapper in saved.definition.visions {
          guard case .createMlImageClassifierVision(let savedVision) = wrapper.vision,
            let index = storeService.workspaceDefinition.visions.firstIndex(where: {
              $0.internalID == savedVision.internalID
            }),
            case .createMlImageClassifierVision(var current) = storeService.workspaceDefinition
              .visions[index].vision,
            original.modelURLs.keys.contains(current.internalID),
            original.workspace.definition.visions.contains(where: {
              guard case .createMlImageClassifierVision(let vision) = $0.vision else { return false }
              return vision.internalID == current.internalID
                && vision.modelFileName == current.modelFileName
            })
          else { continue }
          let key = "\(savedVision.internalID)/\(savedVision.modelFileName)"
          if let data = saved.models[key] { storeService.workspaceModels[key] = data }
          if storeService.modelURLs[current.internalID] == original.modelURLs[current.internalID] {
            storeService.modelURLs.removeValue(forKey: current.internalID)
          }
          current.modelFileName = savedVision.modelFileName
          storeService.workspaceDefinition.visions[index].vision = .createMlImageClassifierVision(
            current)
        }
        isReading = false
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
    if let externalID = storeService.externalID.flatMap(UUID.init(uuidString:)) {
      appletData.migrateOutputData(from: url, externalID: externalID)
    }
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
    do { try editingState.requireConfirmedEdits() } catch {
      editingState.reportInputValidationError(error)
      callback.reviewed(self, shouldClose: false, contextInfo: nil)
      return
    }
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
    outputStateObservationTask?.cancel()
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
