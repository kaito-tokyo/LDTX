// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1006: commit-transform-drafts", .serialized)
  @MainActor
  struct UCT1006VideoLayersEditorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }
    @Test("UCT-1006.1: Validation errors are reported and drafts survive")
    func validationErrorsAreReportedAndDraftsSurvive() throws {
      let fixture = VideoLayersTestFixture()
      let editor = fixture.makeEditor()
      editor.update(
        definition: .init(), programPreferences: .init(), layerIDs: [1, 2],
        canvasWidth: 1920, canvasHeight: 1080,
        onError: { [fixture] in fixture.reportedErrors.append($0.localizedDescription) })
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
      #expect(fixture.reportedErrors[0].contains("Invalid number (Pos X)"))
      #expect(fixture.reportedErrors[1].contains("Invalid number (Scale Y)"))
      #expect(first.state.strings[0] == "bad")
      first.state.strings[0] = "960"
      first.state.onCommit()
      #expect(fixture.reportedErrors.count == 2)
      second.state.strings[3] = "1"
      second.state.onCommit()
      #expect(fixture.reportedErrors.count == 2)

      second.state.strings[3] = "-"
      second.state.hasUnconfirmedChanges = true
      second.state.onCommit()
      editor.table.removeAllRows()
      editor.update(
        definition: .init(), programPreferences: .init(), layerIDs: [1, 2],
        canvasWidth: 1920, canvasHeight: 1080)
      #expect(fixture.reportedErrors.count == 3)
    }

    @Test("UCT-1006.2: Editor and table release wired rows")
    func editorAndTableReleaseWiredRows() {
      let fixture = VideoLayersTestFixture()
      weak var releasedEditor: VideoLayersEditor?
      weak var releasedTable: VideoLayersTableView?
      weak var releasedRow: VideoLayersTableRow?
      var state: VideoLayersTableRowState?
      autoreleasepool {
        let editor = fixture.makeEditor()
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

    @Test("UCT-1006.3: Missing save delegate retains draft and hide")
    func missingSaveDelegateRetainsDraftAndHide() {
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

    @Test("UCT-1006.4: Reflects preferences without overwriting editing text")
    func reflectsPreferencesWithoutOverwritingEditingText() throws {
      let fixture = VideoLayersTestFixture()
      let table = fixture.makeTable()
      fixture.update(table)
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
      fixture.update(table, preferences: preferences)
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
      fixture.update(table, preferences: preferences)
      #expect(row.state.strings[0] == "draft")
      #expect(!row.state.isHidden)
    }

    @Test("UCT-1006.5: Commits normalized numbers on submit")
    func commitsNormalizedNumbersOnSubmit() throws {
      let fixture = VideoLayersTestFixture()
      var saved: [Ldtx_Workspace_V4_BasicTransform] = []
      let table = fixture.makeTable()
      fixture.update(table, commit: { _, value in saved.append(value) })
      let row = try #require(table.rows[1])
      row.state.strings = ["960", "270", "1.5", "2"]
      row.state.hasUnconfirmedChanges = true
      row.state.onCommit()
      #expect(saved.count == 1)
      #expect(
        saved[0].translationXRational
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = 960
            $0.denominator = 1920
          })
      #expect(
        saved[0].translationYRational
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = 270
            $0.denominator = 1080
          })
      #expect(
        saved[0].scaleXRational
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = 15
            $0.denominator = 10
          })
      row.state.strings[0] = "192"
      row.state.hasUnconfirmedChanges = true
      row.state.onCommit()
      #expect(saved.count == 2)
      #expect(
        saved[1].translationXRational
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = 192
            $0.denominator = 1920
          })
      #expect(!row.state.hasUnconfirmedChanges)
    }

    @Test("UCT-1006.6: Positions require integer pixels while scales preserve decimals")
    func positionsRequireIntegerPixelsWhileScalesPreserveDecimals() throws {
      let fixture = VideoLayersTestFixture()
      var saved: Ldtx_Workspace_V4_BasicTransform?
      let table = fixture.makeTable()
      fixture.update(table, commit: { _, value in saved = value })
      let row = try #require(table.rows[1])
      for positions in [
        ["100.125", "0"], ["0", "1/3"], ["-1", "0"], ["1921", "0"], ["0", "1081"],
      ] {
        row.state.strings = positions + ["1.25", "1"]
        row.state.hasUnconfirmedChanges = true
        row.state.onCommit()
        #expect(saved == nil)
        #expect(row.state.hasUnconfirmedChanges)
        #expect(Array(row.state.strings.prefix(2)) == positions)
      }
      for scale in ["7/9", "0.12345678901", "2147483648"] {
        row.state.strings = ["100", "1", scale, "1"]
        row.state.hasUnconfirmedChanges = true
        row.state.onCommit()
        #expect(saved == nil)
        #expect(row.state.hasUnconfirmedChanges)
        #expect(row.state.strings[2] == scale)
      }
      row.state.strings = ["100", "1", "1.25", "1"]
      row.state.onCommit()
      let transform = try #require(saved)
      #expect(transform.translationXRational.numerator == 100)
      #expect(transform.translationXRational.denominator == 1920)
      #expect(transform.translationYRational.numerator == 1)
      #expect(transform.translationYRational.denominator == 1080)
      #expect(transform.scaleXRational.numerator == 125)
      #expect(transform.scaleXRational.denominator == 100)
      #expect(row.state.strings == ["100", "1", "1.25", "1"])
    }

    @Test("UCT-1006.7: App kit commit requests read current draft once")
    func appKitCommitRequestsReadCurrentDraftOnce() throws {
      let fixture = VideoLayersTestFixture()
      var saved: [Ldtx_Workspace_V4_BasicTransform] = []
      let table = fixture.makeTable()
      fixture.update(table, commit: { _, value in saved.append(value) })
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
            $0.numerator = 960
            $0.denominator = 1920
          })
      #expect(row.state.strings[0] == "960")

      row.state.strings[0] = "192"
      row.state.hasUnconfirmedChanges = true
      table.removeAllRows()
      row.state.onCommit()
      #expect(saved.count == 1)
    }

    @Test("UCT-1006.8: Hosted callbacks do not retain row")
    func hostedCallbacksDoNotRetainRow() {
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

    @Test(
      "UCT-1006.9: Invalid input survives model updates", arguments: ["-", "１２", "inf", "1e100"])
    func invalidInputSurvivesModelUpdates(value: String) throws {
      let fixture = VideoLayersTestFixture()
      var commits = 0
      let table = fixture.makeTable()
      fixture.update(table, commit: { _, _ in commits += 1 })
      let row = try #require(table.rows[1])
      row.state.strings[2] = value
      row.state.hasUnconfirmedChanges = true
      row.state.onCommit()
      fixture.update(table, ids: [3, 1, 2])
      #expect(table.rows[1] === row)
      #expect(row.state.strings[2] == value)
      #expect(
        fixture.reportedErrors.contains { $0.contains("Invalid number") })
      #expect(commits == 0)
    }

    @Test("UCT-1006.10: Failure retains draft and can be retried")
    func failureRetainsDraftAndCanBeRetried() throws {
      let fixture = VideoLayersTestFixture()
      let table = fixture.makeTable()
      fixture.update(
        table,
        commit: { _, _ in
          throw NSError(
            domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Save failed."])
        })
      let row = try #require(table.rows[1])
      row.state.strings[0] = "960"
      row.state.hasUnconfirmedChanges = true
      row.state.onCommit()
      #expect(
        fixture.reportedErrors.contains { $0.contains("Save failed.") })
      #expect(row.state.hasUnconfirmedChanges)
      #expect(row.state.strings[0] == "960")
      fixture.update(table)
      row.state.onCommit()
      #expect(!row.state.hasUnconfirmedChanges)
      #expect(row.state.strings[0] == "960")
    }

    @Test("UCT-1006.11: Hosting view renders editable fields")
    func hostingViewRendersEditableFields() throws {
      let fixture = VideoLayersTestFixture()
      let container = fixture.makeContainer()
      container.scrollView.frame = NSRect(x: 0, y: 0, width: 720, height: 308)
      let window = NSWindow(
        contentRect: container.scrollView.frame, styleMask: [.titled], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = container.scrollView
      defer { window.close() }
      fixture.update(container.table)
      window.displayIfNeeded()
      container.scrollView.layoutSubtreeIfNeeded()
      _ = container.table.view(atColumn: 0, row: 0, makeIfNecessary: true)
      let row = try #require(container.table.rows[1])
      row.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      let fields = fixture.nativeFields(in: row)
      #expect(fields.count == 4)
      #expect(fields.allSatisfy { $0.frame.width >= 60 })
      #expect(row.rootView.state === row.state)
      #expect(row.hitTest(row.convert(NSPoint(x: 5, y: 5), to: row.superview)) == nil)
      for field in fields {
        let point = container.table.convert(
          NSPoint(x: field.bounds.midX, y: field.bounds.midY), from: field)
        #expect(!container.table.canDragRows(with: IndexSet(integer: 0), at: point))
      }
      fixture.update(container.table, ids: [3, 2, 1])
      #expect(container.table.rows[1] === row)
      #expect(row.rootView.state === row.state)
    }

    @Test("UCT-1006.12: Hosted fields commit only on enter")
    func hostedFieldsCommitOnlyOnEnter() throws {
      let fixture = VideoLayersTestFixture()
      let container = fixture.makeContainer()
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 308), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = container.scrollView
      defer { window.close() }
      var saved: [Ldtx_Workspace_V4_BasicTransform] = []
      fixture.update(container.table, commit: { _, value in saved.append(value) })
      window.displayIfNeeded()
      container.scrollView.layoutSubtreeIfNeeded()
      let row = try #require(
        container.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? VideoLayersTableRow)
      row.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      let fields = fixture.nativeFields(in: row)
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
            $0.numerator = 960
            $0.denominator = 1920
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
      fixture.update(container.table, ids: [3, 2, 1])
      #expect(container.table.rows[1] === row)
      #expect(row.state.strings[0] == "480")
      container.table.removeAllRows()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      row.state.onCommit()
      #expect(saved.count == 1)
      #expect(container.table.rows.isEmpty)
    }

    @Test("UCT-1006.13: Active editor survives ordinary refresh")
    func activeEditorSurvivesOrdinaryRefresh() throws {
      let fixture = VideoLayersTestFixture()
      let table = fixture.makeTable()
      fixture.update(table)
      let row = try #require(table.rows[1])
      row.state.isEditing = true
      row.state.strings[0] = "192.00000286102295"
      fixture.update(table)
      #expect(row.state.strings[0] == "192.00000286102295")
      #expect(table.rows[1] === row)
      let other = fixture.makeTable()
      fixture.update(other)
      #expect(other.rows[1] !== row)
    }

    @Test("UCT-1006.14: Preference commit uses latest value and preserves insets")
    func preferenceCommitUsesLatestValueAndPreservesInsets() throws {
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
            $0.numerator = 960
            $0.denominator = 1920
          })
      #expect(live.videoLayerHidden[2] == true)
      #expect(state.preferences.portraitProgramPreferences.isEmpty)
      #expect(row.state.strings[0] == "960")
    }

  }
}
