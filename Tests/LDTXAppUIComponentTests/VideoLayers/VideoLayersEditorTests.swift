// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite(.serialized)
  @MainActor
  final class VideoLayersEditorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    private var editors: [ObjectIdentifier: VideoLayersEditor] = [:]
    private var reportedErrors: [String] = []

    @Test func editorOwnsObservationWithoutLoadingViewUntilUsed() async throws {
      let storeService = WorkspaceStoreService(definition: .init(), preferences: .init())
      let editor = VideoLayersEditor(storeService: storeService, target: .landscape)
      #expect(!editor.isViewLoaded)
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 100
      program.landscapeVideoLayerInternalIds = [1]
      storeService.definition.programs = [program]
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentViewController = editor
      window.orderFront(nil)
      defer { window.close() }
      window.contentView?.layoutSubtreeIfNeeded()
      #expect(editor.table.layerIDs == [1])
      storeService.definition.programs[0].landscapeVideoLayerInternalIds = [1, 2]
      for _ in 0..<50 {
        if editor.table.layerIDs == [1, 2] { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(editor.table.layerIDs == [1, 2])
    }

    @Test func hiddenVideoTabUsesLatestStateWhenShown() async throws {
      _ = NSApplication.shared
      let service = WorkspaceStoreService(definition: .init(), preferences: .init())
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 100
      program.landscapeVideoLayerInternalIds = [1]
      program.portraitVideoLayerInternalIds = [2]
      service.definition.programs = [program]
      let landscape = VideoLayersEditor(storeService: service, target: .landscape)
      let portrait = VideoLayersEditor(storeService: service, target: .portrait)
      let tabs = NSTabViewController()
      tabs.addTabViewItem(NSTabViewItem(viewController: landscape))
      tabs.addTabViewItem(NSTabViewItem(viewController: portrait))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentViewController = tabs
      window.orderFront(nil)
      defer { window.close() }
      service.definition.programs[0].portraitVideoLayerInternalIds = [2, 3]
      tabs.selectedTabViewItemIndex = 1
      for _ in 0..<100 {
        if portrait.table.layerIDs == [2, 3] { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(portrait.table.layerIDs == [2, 3])
    }

    @Test func componentInspectorMembershipUsesLatestProgramAndPreservesPreferences() throws {
      let service = WorkspaceStoreService(definition: .init(), preferences: .init())
      var first = Ldtx_Workspace_V4_ProgramDefinition()
      first.internalID = 100
      first.landscapeVideoLayerInternalIds = [20]
      var second = Ldtx_Workspace_V4_ProgramDefinition()
      second.internalID = 200
      service.definition.programs = [first, second]
      service.definition.videoComponents = [10, 20].map {
        WorkspaceResourceFactory.makeSolidColor(id: UInt64($0), name: "Color \($0)")
      }
      service.preferences.landscapeProgramPreferences[100, default: .init()].videoLayerHidden[10] =
        true
      let preferences = service.preferences
      let controls = VideoComponentProgramLayers(
        storeService: service, componentID: .solidColorFill(10))
      let landscape = controls.membership(for: 100, target: .landscape)
      let portrait = controls.membership(for: 100, target: .portrait)
      #expect(!landscape.wrappedValue && !portrait.wrappedValue)
      landscape.wrappedValue = true
      landscape.wrappedValue = true
      portrait.wrappedValue = true
      #expect(service.definition.programs[0].landscapeVideoLayerInternalIds == [20, 10])
      #expect(service.definition.programs[0].portraitVideoLayerInternalIds == [10])
      landscape.wrappedValue = false
      #expect(service.definition.programs[0].landscapeVideoLayerInternalIds == [20])
      #expect(portrait.wrappedValue)
      #expect(service.preferences == preferences)
      service.isOutputActive = true
      portrait.wrappedValue = false
      #expect(portrait.wrappedValue)
      service.isOutputActive = false
      service.definition.programs.swapAt(0, 1)
      portrait.wrappedValue = false
      #expect(service.definition.programs[1].portraitVideoLayerInternalIds == [10])
      let newProgram = controls.membership(for: 200, target: .portrait)
      newProgram.wrappedValue = true
      #expect(service.definition.programs[0].portraitVideoLayerInternalIds == [10])
      service.definition.videoComponents.removeAll { $0.id == .solidColorFill(10) }
      newProgram.wrappedValue = false
      #expect(service.definition.programs[0].portraitVideoLayerInternalIds == [10])
      #expect(throws: WorkspaceSelectionError.self) {
        try service.setVideoLayerIncluded(
          true, componentID: 999, programID: 200, target: .landscape)
      }
      #expect(throws: WorkspaceSelectionError.self) {
        try service.setVideoLayerIncluded(true, componentID: 20, programID: 999, target: .landscape)
      }
    }

    func makeEditor() -> VideoLayersEditor {
      let editor = VideoLayersEditor(
        storeService: WorkspaceStoreService(definition: .init(), preferences: .init()),
        target: .landscape)
      _ = editor.view
      return editor
    }

    func makeTable() -> VideoLayersTableView {
      let editor = makeEditor()
      editors[ObjectIdentifier(editor.table)] = editor
      return editor.table
    }

    func makeContainer() -> (scrollView: NSScrollView, table: VideoLayersTableView) {
      let table = makeTable()
      let scrollView = NSScrollView()
      scrollView.hasVerticalScroller = true
      scrollView.documentView = table
      return (scrollView, table)
    }

    @Test func previewConstraintsPreserveEditorSize() {
      let editor = makeEditor()
      editor.update(
        definition: .init(), programPreferences: .init(), layerIDs: [1, 2],
        canvasWidth: 1920, canvasHeight: 1080)
      NSLayoutConstraint.activate([
        editor.view.widthAnchor.constraint(equalToConstant: 720),
        editor.view.heightAnchor.constraint(equalToConstant: 360),
      ])
      #expect(editor.view.fittingSize == NSSize(width: 720, height: 360))
    }

    @Test func editorRowsUseAvailableWidth() throws {
      let service = WorkspaceStoreService(definition: .init(), preferences: .init())
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 100
      program.landscapeVideoLayerInternalIds = [1, 2]
      service.definition.programs = [program]
      let editor = VideoLayersEditor(storeService: service, target: .landscape)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentViewController = editor
      window.setContentSize(NSSize(width: 720, height: 360))
      window.contentView?.layoutSubtreeIfNeeded()
      let row = try #require(
        editor.table.view(atColumn: 0, row: 0, makeIfNecessary: true)
          as? VideoLayersTableRow)
      row.layoutSubtreeIfNeeded()
      #expect(editor.table.enclosingScrollView == nil)
      #expect(editor.table.frame.width >= 690)
      #expect(editor.table.frame.height >= editor.table.intrinsicContentSize.height - 0.5)
      #expect(editor.table.rect(ofRow: 1).maxY <= editor.table.bounds.height + 0.5)
      #expect(row.frame.width >= 670)
      #expect(row.rootView.state === row.state)
      #expect(row.rootView.canvasWidth == 1920)
      #expect(row.rootView.canvasHeight == 1080)
    }
    func update(
      _ table: VideoLayersTableView,
      ids: [UInt64] = [1, 2, 3],
      preferences: Ldtx_Workspace_V4_ProgramPreferences = .init(),
      commit: @escaping (UInt64, Ldtx_Workspace_V4_BasicTransform) throws -> Void = { _, _ in },
      order: @escaping ([UInt64]) throws -> Void = { _ in },
      setHidden: @escaping (UInt64, Bool) throws -> Void = { _, _ in },
      onError: @escaping (Error) -> Void = { _ in }
    ) {
      let editor = editors[ObjectIdentifier(table)] ?? makeEditor()
      editors[ObjectIdentifier(table)] = editor
      editor.update(
        definition: .init(), programPreferences: preferences, layerIDs: ids,
        canvasWidth: 1920, canvasHeight: 1080,
        onCommitTransform: { id, value in
          try commit(id, value)
          return value
        },
        onSetHidden: setHidden, onCommitLayerOrder: order,
        onError: { [self] error in
          reportedErrors.append(error.localizedDescription)
          onError(error)
        })
      if editor.table !== table {
        table.update(
          layerIDs: ids, rows: editor.table.rows,
          onCommitLayerOrder: order, onError: onError)
      }
    }

    @Test func editorReusesRowsAndRefreshesSaveConnections() throws {
      let editor = makeEditor()
      var saved: [UInt64] = []
      editor.update(
        definition: .init(), programPreferences: .init(), layerIDs: [1, 2],
        canvasWidth: 1920, canvasHeight: 1080,
        onCommitTransform: { id, value in
          saved.append(id)
          return value
        })
      let row = try #require(editor.table.rows[1])
      #expect(row.delegate === editor)
      row.state.strings[0] = "960"
      row.state.hasUnconfirmedChanges = true
      editor.update(
        definition: .init(), programPreferences: .init(), layerIDs: [2, 1],
        canvasWidth: 1920, canvasHeight: 1080,
        onCommitTransform: { id, value in
          saved.append(id + 100)
          return value
        })
      #expect(editor.table.rows[1] === row)
      #expect(row.state.strings[0] == "960")
      row.state.onCommit()
      #expect(saved == [101])
      editor.update(
        definition: .init(), programPreferences: .init(), layerIDs: [2, 1],
        canvasWidth: 1080, canvasHeight: 1920)
      let replacement = try #require(editor.table.rows[1])
      #expect(replacement !== row)
      #expect(replacement.rootView.canvasWidth == 1080)
      #expect(replacement.rootView.canvasHeight == 1920)
      #expect(!row.state.hasUnconfirmedChanges)
    }

    @Test func validationErrorsAreReportedAndDraftsSurvive() throws {
      let editor = makeEditor()
      editor.update(
        definition: .init(), programPreferences: .init(), layerIDs: [1, 2],
        canvasWidth: 1920, canvasHeight: 1080,
        onError: { [self] in reportedErrors.append($0.localizedDescription) })
      let first = try #require(editor.table.rows[1])
      let second = try #require(editor.table.rows[2])
      first.state.name = "Camera"
      second.state.name = "Background"
      first.state.strings[0] = "bad"
      second.state.strings[3] = "inf"
      first.state.hasUnconfirmedChanges = true
      second.state.hasUnconfirmedChanges = true
      first.state.onCommit()
      second.state.onCommit()
      #expect(reportedErrors[0].contains("Invalid number (Pos X)"))
      #expect(reportedErrors[1].contains("Invalid number (Scale Y)"))
      #expect(first.state.strings[0] == "bad")
      first.state.strings[0] = "960"
      first.state.onCommit()
      #expect(reportedErrors.count == 2)
      second.state.strings[3] = "1"
      second.state.onCommit()
      #expect(reportedErrors.count == 2)

      second.state.strings[3] = "-"
      second.state.hasUnconfirmedChanges = true
      second.state.onCommit()
      editor.table.removeAllRows()
      editor.update(
        definition: .init(), programPreferences: .init(), layerIDs: [1, 2],
        canvasWidth: 1920, canvasHeight: 1080)
      #expect(reportedErrors.count == 3)
    }

    @Test func editorAndTableReleaseWiredRows() {
      weak var releasedEditor: VideoLayersEditor?
      weak var releasedTable: VideoLayersTableView?
      weak var releasedRow: VideoLayersTableRow?
      var state: VideoLayersTableRowState?
      autoreleasepool {
        let editor = makeEditor()
        editor.update(
          definition: .init(), programPreferences: .init(), layerIDs: [1],
          canvasWidth: 1920, canvasHeight: 1080)
        releasedEditor = editor
        releasedTable = editor.table
        releasedRow = editor.table.rows[1]
        state = releasedRow?.state
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      #expect(releasedEditor == nil)
      #expect(releasedTable == nil)
      #expect(releasedRow == nil)
      #expect(state != nil)
      state?.onCommit()
      state?.onSetHidden(true)
    }

    @Test func missingSaveDelegateRetainsDraftAndHide() {
      let row = VideoLayersTableRow(
        rootView: VideoLayersTableRowContent(
          state: VideoLayersTableRowState(), canvasWidth: 1920, canvasHeight: 1080))
      row.state.strings[0] = "960"
      row.state.hasUnconfirmedChanges = true
      row.state.onCommit()
      row.state.onSetHidden(true)
      #expect(row.state.hasUnconfirmedChanges)
      #expect(row.state.strings[0] == "960")
      #expect(!row.state.isHidden)
    }

    @Test func resolvesAndUpdatesNamesFromDefinition() throws {
      var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
      var device = Ldtx_Workspace_V4_VfxSourceComponent()
      device.internalID = 1
      device.displayName = "Camera"
      var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      wrapper.vfxSource = device
      definition.videoComponents = [wrapper]
      var clock = Ldtx_Workspace_V4_ClockComponent()
      clock.internalID = 3
      clock.displayName = "Clock"
      var component = Ldtx_Workspace_V4_VideoComponentWrapper()
      component.clock = clock
      definition.videoComponents.append(component)
      let editor = makeEditor()
      let table = editor.table
      editor.update(
        definition: definition, programPreferences: .init(), layerIDs: [1, 2, 3], canvasWidth: 1920,
        canvasHeight: 1080)
      let row = try #require(table.rows[1])
      #expect(row.state.name == "Camera")
      #expect(table.rows[3]?.state.name == "Clock")
      definition.videoComponents[0].vfxSource.displayName = "Renamed"
      editor.update(
        definition: definition, programPreferences: .init(), layerIDs: [1, 2, 3], canvasWidth: 1920,
        canvasHeight: 1080)
      #expect(table.rows[1] === row)
      #expect(row.state.name == "Renamed")
      #expect(table.rows[2]?.state.name == "Missing Video Layer")
    }

    @Test func reflectsPreferencesWithoutOverwritingEditingText() throws {
      let table = makeTable()
      update(table)
      let row = try #require(table.rows[1])
      var preferences = Ldtx_Workspace_V4_ProgramPreferences()
      var transform = Ldtx_Workspace_V4_BasicTransform()
      transform.translationXRational = .with {
        $0.numerator = 1
        $0.denominator = 2
      }
      transform.scaleXRational = .with {
        $0.numerator = 1
        $0.denominator = 1
      }
      transform.scaleYRational = .with {
        $0.numerator = 1
        $0.denominator = 1
      }
      preferences.videoLayerTransforms[1] = transform
      preferences.videoLayerHidden[1] = true
      update(table, preferences: preferences)
      #expect(table.rows[1] === row)
      #expect(row.state.strings[0] == "960")
      #expect(row.state.isHidden)
      row.state.isEditing = true
      row.state.strings[0] = "draft"
      preferences.videoLayerTransforms[1]?.translationXRational = .with {
        $0.numerator = 1
        $0.denominator = 4
      }
      preferences.videoLayerHidden[1] = false
      update(table, preferences: preferences)
      #expect(row.state.strings[0] == "draft")
      #expect(!row.state.isHidden)
    }

    @Test func commitsNormalizedNumbersOnSubmit() throws {
      var saved: [Ldtx_Workspace_V4_BasicTransform] = []
      let table = makeTable()
      update(table, commit: { _, value in saved.append(value) })
      let row = try #require(table.rows[1])
      row.state.strings = ["960", "270", "1.5", "2"]
      row.state.hasUnconfirmedChanges = true
      row.state.onCommit()
      #expect(saved.count == 1)
      #expect(
        saved[0].translationXRational
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = 1
            $0.denominator = 2
          })
      #expect(
        saved[0].translationYRational
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = 1
            $0.denominator = 4
          })
      #expect(
        saved[0].scaleXRational
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = 3
            $0.denominator = 2
          })
      row.state.strings[0] = "192"
      row.state.hasUnconfirmedChanges = true
      row.state.onCommit()
      #expect(saved.count == 2)
      #expect(
        saved[1].translationXRational
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = 1
            $0.denominator = 10
          })
      #expect(!row.state.hasUnconfirmedChanges)
    }

    @Test func exactFractionalPixelsSurviveCommitAndRestore() throws {
      var saved: Ldtx_Workspace_V4_BasicTransform?
      let table = makeTable()
      update(table, commit: { _, value in saved = value })
      let row = try #require(table.rows[1])
      row.state.strings = ["100.125", "1/3", "7/9", "1"]
      row.state.hasUnconfirmedChanges = true
      row.state.onCommit()
      #expect(saved != nil)
      #expect(row.state.strings == ["100.125", "1/3", "7/9", "1"])
    }

    @Test func appKitCommitRequestsReadCurrentDraftOnce() throws {
      var saved: [Ldtx_Workspace_V4_BasicTransform] = []
      let table = makeTable()
      update(table, commit: { _, value in saved.append(value) })
      let row = try #require(table.rows[1])
      row.state.strings = ["960", "270", "1.5", "2"]
      row.state.hasUnconfirmedChanges = true
      row.state.onCommit()
      row.state.onCommit()
      row.state.onCommit()
      #expect(saved.count == 1)
      #expect(
        saved.first?.translationXRational
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = 1
            $0.denominator = 2
          })
      #expect(row.state.strings[0] == "960")

      row.state.strings[0] = "192"
      row.state.hasUnconfirmedChanges = true
      table.removeAllRows()
      row.state.onCommit()
      #expect(saved.count == 1)
    }

    @Test func hostedCallbacksDoNotRetainRow() {
      weak var releasedRow: VideoLayersTableRow?
      var content: VideoLayersTableRowContent?
      autoreleasepool {
        let row = VideoLayersTableRow(
          rootView: VideoLayersTableRowContent(
            state: VideoLayersTableRowState(), canvasWidth: 1920, canvasHeight: 1080))
        row.state.onCommit = { [weak row] in
          guard let row else { return }
          row.delegate?.videoLayersTableRowDidRequestCommit(row)
        }
        row.state.onSetHidden = { [weak row] value in
          guard let row else { return }
          row.delegate?.videoLayersTableRow(row, setHidden: value)
        }
        releasedRow = row
        content = row.rootView
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      #expect(releasedRow == nil)
      content?.state.onCommit()
      content?.state.onSetHidden(true)
    }

    @Test(arguments: ["-", "１２", "inf", "1e100"])
    func invalidInputSurvivesModelUpdates(value: String) throws {
      var commits = 0
      let table = makeTable()
      update(table, commit: { _, _ in commits += 1 })
      let row = try #require(table.rows[1])
      row.state.strings[2] = value
      row.state.hasUnconfirmedChanges = true
      row.state.onCommit()
      update(table, ids: [3, 1, 2])
      #expect(table.rows[1] === row)
      #expect(row.state.strings[2] == value)
      #expect(
        reportedErrors.contains { $0.contains("Invalid number") })
      #expect(commits == 0)
    }

    @Test func failureRetainsDraftAndCanBeRetried() throws {
      let table = makeTable()
      update(
        table,
        commit: { _, _ in
          throw NSError(
            domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Save failed."])
        })
      let row = try #require(table.rows[1])
      row.state.strings[0] = "960.000"
      row.state.hasUnconfirmedChanges = true
      row.state.onCommit()
      #expect(
        reportedErrors.contains { $0.contains("Save failed.") })
      #expect(row.state.hasUnconfirmedChanges)
      #expect(row.state.strings[0] == "960.000")
      update(table)
      row.state.onCommit()
      #expect(!row.state.hasUnconfirmedChanges)
      #expect(row.state.strings[0] == "960")
    }

    @Test func usesStandardRowDragging() throws {
      let container = makeContainer()
      let table = container.table
      container.scrollView.frame = NSRect(x: 0, y: 0, width: 720, height: 308)
      let window = NSWindow(
        contentRect: container.scrollView.frame, styleMask: [.titled], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = container.scrollView
      defer { window.close() }
      update(table)
      window.displayIfNeeded()
      container.scrollView.layoutSubtreeIfNeeded()
      let cell = try #require(
        table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? VideoLayersTableRow)
      cell.layoutSubtreeIfNeeded()
      let name = table.convert(NSPoint(x: 10, y: 10), from: cell)
      #expect(table.canDragRows(with: IndexSet(integer: 0), at: name))
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      table.layoutSubtreeIfNeeded()
      let bounds = table.rect(ofRow: 0)
      let boundary = bounds.minY + VideoLayersTableView.dragRegionHeight
      #expect(
        table.canDragRows(
          with: IndexSet(integer: 0), at: NSPoint(x: bounds.midX, y: boundary - 1)))
      #expect(
        !table.canDragRows(
          with: IndexSet(integer: 0), at: NSPoint(x: bounds.midX, y: boundary)))
      #expect(
        !table.canDragRows(
          with: IndexSet(integer: 0), at: NSPoint(x: bounds.midX, y: bounds.maxY - 1)))

    }

    @Test func acceptsSingleLocalMovesAndRejectsForeign() throws {
      let table = makeTable()
      var actions: [[UInt64]] = []
      update(table, order: { actions.append($0) })
      let info = LayerDraggingInfo(source: table, id: 3)
      #expect(
        table.tableView(
          table, validateDrop: info, proposedRow: 0,
          proposedDropOperation: .above) == .move)
      #expect(table.tableView(table, acceptDrop: info, row: 0, dropOperation: .above))
      #expect(actions.count == 1)
      #expect(
        actions[0] == [3, 1, 2])
      let toEnd = LayerDraggingInfo(source: table, id: 1)
      #expect(table.tableView(table, acceptDrop: toEnd, row: 3, dropOperation: .above))
      #expect(actions[1] == [2, 3, 1])
      #expect(table.tableView(table, acceptDrop: toEnd, row: 2, dropOperation: .above))
      #expect(actions[2] == [2, 1, 3])
      let foreign = LayerDraggingInfo(source: VideoLayersTableView(), id: 1)
      #expect(!table.tableView(table, acceptDrop: foreign, row: 0, dropOperation: .above))
      let missing = LayerDraggingInfo(source: table, id: 999)
      #expect(!table.tableView(table, acceptDrop: missing, row: 0, dropOperation: .above))
      #expect(!table.tableView(table, acceptDrop: toEnd, row: 4, dropOperation: .above))
      #expect(!table.tableView(table, acceptDrop: toEnd, row: 1, dropOperation: .on))

    }

    @Test func lowerHalfOfLastRowTargetsEndInsertion() {
      let table = DropRecordingTable()
      table.frame = NSRect(x: 0, y: 0, width: 720, height: 308)
      var actions: [[UInt64]] = []
      update(table, order: { actions.append($0) })
      let info = LayerDraggingInfo(source: table, id: 1)
      info.draggingLocation = table.convert(
        NSPoint(x: 40, y: table.rect(ofRow: 2).midY + 1), to: nil)
      #expect(
        table.tableView(
          table, validateDrop: info, proposedRow: 2,
          proposedDropOperation: .on) == .move)
      #expect(table.insertionRow == 3)
      #expect(
        table.tableView(table, acceptDrop: info, row: table.insertionRow, dropOperation: .above))
      #expect(actions == [[2, 3, 1]])
      info.draggingLocation = table.convert(
        NSPoint(x: 40, y: table.rect(ofRow: 2).midY - 1), to: nil)
      #expect(
        table.tableView(
          table, validateDrop: info, proposedRow: 2,
          proposedDropOperation: .on) == .move)
      #expect(table.insertionRow == 2)
      #expect(
        table.tableView(
          table, validateDrop: info, proposedRow: 3,
          proposedDropOperation: .above) == .move)
      #expect(table.insertionRow == 3)
    }

    @Test func hostingViewRendersEditableFields() throws {
      let container = makeContainer()
      container.scrollView.frame = NSRect(x: 0, y: 0, width: 720, height: 308)
      let window = NSWindow(
        contentRect: container.scrollView.frame, styleMask: [.titled], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = container.scrollView
      defer { window.close() }
      update(container.table)
      window.displayIfNeeded()
      container.scrollView.layoutSubtreeIfNeeded()
      _ = container.table.view(atColumn: 0, row: 0, makeIfNecessary: true)
      let row = try #require(container.table.rows[1])
      row.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      let fields = nativeFields(in: row)
      #expect(fields.count == 4)
      #expect(fields.allSatisfy { $0.frame.width >= 60 })
      #expect(row.rootView.state === row.state)
      #expect(row.hitTest(row.convert(NSPoint(x: 5, y: 5), to: row.superview)) == nil)
      for field in fields {
        let point = container.table.convert(
          NSPoint(x: field.bounds.midX, y: field.bounds.midY), from: field)
        #expect(!container.table.canDragRows(with: IndexSet(integer: 0), at: point))
      }
      update(container.table, ids: [3, 2, 1])
      #expect(container.table.rows[1] === row)
      #expect(row.rootView.state === row.state)
    }

    @Test func hostedFieldsCommitOnlyOnEnter() throws {
      let container = makeContainer()
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 308), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = container.scrollView
      defer { window.close() }
      var saved: [Ldtx_Workspace_V4_BasicTransform] = []
      update(container.table, commit: { _, value in saved.append(value) })
      window.displayIfNeeded()
      container.scrollView.layoutSubtreeIfNeeded()
      let row = try #require(
        container.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? VideoLayersTableRow)
      row.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      let fields = nativeFields(in: row)
      try #require(fields.count == 4)
      #expect(window.makeFirstResponder(fields[0]))
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      let editor = try #require(fields[0].currentEditor() as? NSTextView)
      editor.insertText(
        "960", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
      #expect(window.makeFirstResponder(fields[1]))
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      #expect(saved.isEmpty)
      #expect(row.state.strings[0] == "960")
      #expect(row.state.hasUnconfirmedChanges)
      let secondEditor = try #require(fields[1].currentEditor() as? NSTextView)
      secondEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      #expect(saved.count == 1)
      #expect(
        saved.first?.translationXRational
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = 1
            $0.denominator = 2
          })
      #expect(!row.state.hasUnconfirmedChanges)

      #expect(window.makeFirstResponder(fields[0]))
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      let nextEditor = try #require(fields[0].currentEditor() as? NSTextView)
      nextEditor.insertText(
        "480", replacementRange: NSRange(location: 0, length: nextEditor.string.utf16.count))
      #expect(window.makeFirstResponder(container.table))
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      #expect(saved.count == 1)
      #expect(!row.state.isEditing)
      #expect(row.state.hasUnconfirmedChanges)
      update(container.table, ids: [3, 2, 1])
      #expect(container.table.rows[1] === row)
      #expect(row.state.strings[0] == "480")
      container.table.removeAllRows()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      row.state.onCommit()
      #expect(saved.count == 1)
      #expect(container.table.rows.isEmpty)
    }

    func nativeFields(in view: NSView) -> [NSTextField] {
      if let field = view as? NSTextField, field.isEditable { return [field] }
      return view.subviews.flatMap { nativeFields(in: $0) }
    }

    @Test func containerScrollsIndependentlyAndUpdatesRowsInPlace() throws {
      let container = makeContainer()
      container.scrollView.frame = NSRect(x: 0, y: 0, width: 720, height: 308)
      update(container.table)
      container.scrollView.layoutSubtreeIfNeeded()
      #expect(container.scrollView.hasVerticalScroller)
      #expect(container.table.frame.width == container.scrollView.contentSize.width)
      // The full-width AppKit style retains a small standard cell gutter.
      #expect(container.table.tableColumns[0].width >= container.scrollView.contentSize.width - 16)
      let first = try #require(container.table.rows[1])
      update(container.table, ids: [3, 1, 4])
      #expect(container.table.rows[1] === first)
      #expect(container.table.rows[2] == nil)
      #expect(container.table.rows[4] != nil)
      #expect(container.table.layerIDs == [3, 1, 4])
      update(container.table, ids: [])
      #expect(container.table.rows.isEmpty)
      update(container.table, ids: [1])
      #expect(container.table.rows[1] !== first)
      container.scrollView.frame = NSRect(x: 0, y: 0, width: 650, height: 116)
      container.scrollView.layoutSubtreeIfNeeded()
      #expect(container.table.frame.width == container.scrollView.contentSize.width)
      // The full-width AppKit style retains a small standard cell gutter.
      #expect(container.table.tableColumns[0].width >= container.scrollView.contentSize.width - 16)
    }

    @Test func activeEditorSurvivesOrdinaryRefresh() throws {
      let table = makeTable()
      update(table)
      let row = try #require(table.rows[1])
      row.state.isEditing = true
      row.state.strings[0] = "192.00000286102295"
      update(table)
      #expect(row.state.strings[0] == "192.00000286102295")
      #expect(table.rows[1] === row)
      let other = makeTable()
      update(other)
      #expect(other.rows[1] !== row)
    }

    @Test func mixedMembershipAndOrderUpdatesKeepRetainedRows() throws {
      let container = makeContainer()
      container.scrollView.frame = NSRect(x: 0, y: 0, width: 720, height: 500)
      let table = container.table
      update(table, ids: [1, 2, 3, 4])
      container.scrollView.layoutSubtreeIfNeeded()
      for index in 0..<4 { _ = table.view(atColumn: 0, row: index, makeIfNecessary: true) }
      let retained = try #require(table.rows[3])
      retained.state.strings[0] = "draft"
      retained.state.hasUnconfirmedChanges = true
      for ids: [UInt64] in [[4, 3, 1, 2], [5, 3, 2], [2, 5, 3, 6], []] {
        update(table, ids: ids)
        container.scrollView.layoutSubtreeIfNeeded()
        #expect(table.numberOfRows == ids.count)
        for (index, id) in ids.enumerated() {
          let row = try #require(
            table.view(atColumn: 0, row: index, makeIfNecessary: true) as? VideoLayersTableRow)
          #expect(row === table.rows[id])
        }
        if ids.contains(3) {
          #expect(table.rows[3] === retained)
          #expect(retained.state.strings[0] == "draft")
        }
      }
      #expect(table.rows.isEmpty)
    }
  }
}

@MainActor
private final class LayerDraggingInfo: NSObject, NSDraggingInfo {
  let draggingSource: Any?
  let draggingPasteboard = NSPasteboard.withUniqueName()
  var draggingDestinationWindow: NSWindow? { nil }
  var draggingSourceOperationMask: NSDragOperation { .move }
  var draggingLocation: NSPoint = .zero
  var draggedImageLocation: NSPoint { .zero }
  nonisolated var draggedImage: NSImage? { nil }
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation: NSDraggingFormation = .none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }

  init(source: VideoLayersTableView, id: UInt64) {
    draggingSource = source
    super.init()
    let item = NSPasteboardItem()
    item.setString(String(id), forType: VideoLayersTableView.pasteboardType)
    draggingPasteboard.writeObjects([item])
  }

  func slideDraggedImage(to screenPoint: NSPoint) {}
  nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL)
    -> [String]?
  { nil }
  func resetSpringLoading() {}
  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions,
    for view: NSView?, classes classArray: [AnyClass],
    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}
}

@MainActor
private final class DropRecordingTable: VideoLayersTableView {
  var insertionRow = -1
  override func setDropRow(_ row: Int, dropOperation: NSTableView.DropOperation) {
    insertionRow = row
    super.setDropRow(row, dropOperation: dropOperation)
  }
}

extension AppUIComponentTestSuite.VideoLayersEditorIntegrationTestSuite {
  @Test func preferenceCommitUsesLatestValueAndPreservesInsets() throws {
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 1
    program.landscapeVideoLayerInternalIds = [1, 2]
    state.definition.programs = [program]
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.scaleXRational = .with {
      $0.numerator = 1
      $0.denominator = 1
    }
    transform.scaleYRational = .with {
      $0.numerator = 1
      $0.denominator = 1
    }
    state.preferences.landscapeProgramPreferences[1, default: .init()].videoLayerTransforms[1] =
      transform
    let content = VideoLayersEditor(
      storeService: state, target: .landscape)
    content.refresh()
    let row = try #require(content.table.rows[1])
    state.preferences.landscapeProgramPreferences[1, default: .init()]
      .audioMasterVolumeDecibels = .with {
        $0.numerator = -9
        $0.denominator = 1
      }
    state.preferences.landscapeProgramPreferences[1, default: .init()].videoLayerTransforms[
      1, default: .init()
    ].topInsetRational = .with {
      $0.numerator = 1
      $0.denominator = 5
    }
    state.preferences.landscapeProgramPreferences[1, default: .init()].videoLayerHidden[2] = true
    row.state.strings[0] = "960"
    row.state.hasUnconfirmedChanges = true
    row.state.onCommit()
    let live = state.preferences.landscapeProgramPreferences[1] ?? .init()
    #expect(
      live.audioMasterVolumeDecibels
        == Ldtx_Workspace_V4_Rational32.with {
          $0.numerator = -9
          $0.denominator = 1
        })
    #expect(
      live.videoLayerTransforms[1]?.topInsetRational
        == Ldtx_Workspace_V4_Rational32.with {
          $0.numerator = 1
          $0.denominator = 5
        })
    #expect(
      live.videoLayerTransforms[1]?.translationXRational
        == Ldtx_Workspace_V4_Rational32.with {
          $0.numerator = 1
          $0.denominator = 2
        })
    #expect(live.videoLayerHidden[2] == true)
    #expect(state.preferences.portraitProgramPreferences.isEmpty)
    #expect(row.state.strings[0] == "960")
  }

  @Test func hideCallbacksRestoreStateOnFailure() throws {
    let table = makeTable()
    var saved: [(UInt64, Bool)] = []
    var failures = 0
    update(table, ids: [1], setHidden: { id, hidden in saved.append((id, hidden)) })
    let row = try #require(table.rows[1])
    row.state.onSetHidden(!row.state.isHidden)
    #expect(saved.count == 1)
    #expect(saved[0].0 == 1 && saved[0].1)
    update(
      table, ids: [1],
      setHidden: { _, _ in throw WorkspaceSelectionError(message: "Rejected") },
      onError: { _ in failures += 1 })
    row.state.onSetHidden(!row.state.isHidden)
    #expect(!row.state.isHidden)
    #expect(failures == 1)
    #expect(table.rows[1] === row)
  }

  @Test func failedOrderCommitDoesNotAcceptDrop() {
    let table = makeTable()
    var failures = 0
    update(
      table, order: { _ in throw WorkspaceSelectionError(message: "Rejected") },
      onError: { _ in failures += 1 })
    #expect(
      !table.tableView(
        table, acceptDrop: LayerDraggingInfo(source: table, id: 1), row: 3, dropOperation: .above))
    #expect(table.layerIDs == [1, 2, 3])
    #expect(failures == 1)
  }

  @Test func changingProgramDiscardsTransformDraft() throws {
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 1
    program.landscapeVideoLayerInternalIds = [1, 2, 3]
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    let state = WorkspaceStoreService(definition: definition, preferences: .init())
    let content = VideoLayersEditor(
      storeService: state, target: .landscape)
    let editor = content
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = content
    defer {
      window.close()
    }
    content.refresh()
    let old = try #require(editor.table.rows[1])
    old.state.strings[0] = "draft"
    old.state.hasUnconfirmedChanges = true
    state.definition.programs[0].internalID = 2
    content.refresh()
    #expect(editor.table.rows[1] !== old)
    #expect(editor.table.rows[1]?.state.hasUnconfirmedChanges == false)
  }

  @Test func audioNumericDraftSurvivesRefreshAndFailure() {
    let field = AudioDecibelField()
    field.configure(
      value: .with {
        $0.numerator = 0
        $0.denominator = 1
      }, enabled: true
    ) { _ in false }
    field.stringValue = "-12.5"
    field.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: field))
    field.configure(
      value: .with {
        $0.numerator = -4
        $0.denominator = 1
      }, enabled: true
    ) { _ in false }
    #expect(field.stringValue == "-12.5")
    field.commit()
    #expect(field.dirty)
    var committed = 0.0
    field.configure(
      value: .with {
        $0.numerator = -4
        $0.denominator = 1
      }, enabled: true
    ) {
      committed = $0.double
      return true
    }
    field.commit()
    #expect(committed == -12.5)
    #expect(!field.dirty)
  }
}

extension AppUIComponentTestSuite.VideoLayersEditorIntegrationTestSuite {
  @Test func monitorDeviceSheetStartsUnselectedAndClearsUnavailableDraft() throws {
    let name = "MonitorSheet-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("saved", forKey: WorkspaceAudioEngine.outputDevicePreferenceKey)
    var devices: [(uid: String, name: String)] = [("saved", "Saved Device"), ("new", "New Device")]
    let sheet = MonitorOutputDeviceSheet(defaults: defaults, deviceProvider: { devices })
    defer { sheet.stop() }
    #expect(sheet.selectedUID == nil)
    #expect(sheet.table.selectedRow == -1)
    #expect(sheet.currentLabel.stringValue == "Saved Device")
    #expect(!sheet.applyButton.isEnabled)
    sheet.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    let selected = try #require(sheet.selectedUID)
    sheet.refreshDevices()
    #expect(sheet.selectedUID == selected)
    devices.removeAll { $0.uid == selected }
    sheet.refreshDevices()
    #expect(sheet.selectedUID == nil)
    #expect(!sheet.applyButton.isEnabled)
    #expect(defaults.string(forKey: WorkspaceAudioEngine.outputDevicePreferenceKey) == "saved")
    var closed = false
    sheet.onClose = { closed = true }
    sheet.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    sheet.applyButton.performClick(nil)
    #expect(closed)
    #expect(
      defaults.string(forKey: WorkspaceAudioEngine.outputDevicePreferenceKey) == devices[0].uid)
  }
}
