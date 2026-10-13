// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXBackgroundSegmentation
import LDTXProtos
@testable import LDTXWorkspaceAppletUI
import LDTXYouTubeRTMPS
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1006: commit-transform-drafts", .serialized)
  @MainActor
  struct UCT1006VideoLayersEditorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }
    @Test("UCT-1006.1: Incomplete text remains local without reporting a validation error")
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
      first.state.hasLocalTextChanges = true
      second.state.hasLocalTextChanges = true
      first.state.onCommit()
      second.state.onCommit()
      #expect(fixture.reportedErrors.isEmpty)
      #expect(first.state.strings[0] == "bad")
      first.state.strings[0] = "960"
      first.state.onCommit()
      #expect(fixture.reportedErrors.isEmpty)
      second.state.strings[3] = "1"
      second.state.onCommit()
      #expect(fixture.reportedErrors.isEmpty)

      second.state.strings[3] = "-"
      second.state.hasLocalTextChanges = true
      second.state.onCommit()
      editor.table.removeAllRows()
      editor.update(
        definition: .init(), programPreferences: .init(), layerIDs: [1, 2],
        canvasWidth: 1920, canvasHeight: 1080)
      #expect(fixture.reportedErrors.isEmpty)
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
      row.state.hasLocalTextChanges = true
      row.state.onCommit()
      row.state.onSetHidden(true)
      #expect(row.state.hasLocalTextChanges)
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
      transform.translationX = .with {
        $0.num = 1
        $0.den = 2
      }
      transform.scaleX = .with {
        $0.num = 1
        $0.den = 1
      }
      transform.scaleY = .with {
        $0.num = 1
        $0.den = 1
      }
      preferences.videoLayerTransforms[1] = transform
      preferences.videoLayerHidden[1] = true
      fixture.update(table, preferences: preferences)
      #expect(table.rows[1] === row)
      #expect(row.state.strings[0] == "960")
      #expect(row.state.isHidden)
      row.state.isEditing = true
      row.state.strings[0] = "draft"
      preferences.videoLayerTransforms[1]?.translationX = .with {
        $0.num = 1
        $0.den = 4
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
      row.state.hasLocalTextChanges = true
      row.state.onCommit()
      #expect(saved.count == 1)
      #expect(
        saved[0].translationX
          == Ldtx_Workspace_V4_Rational32.with {
            $0.num = 960
            $0.den = 1920
          })
      #expect(
        saved[0].translationY
          == Ldtx_Workspace_V4_Rational32.with {
            $0.num = 270
            $0.den = 1080
          })
      #expect(
        saved[0].scaleX
          == Ldtx_Workspace_V4_Rational32DefaultOne.with {
            $0.num = 15
            $0.den = 10
          })
      row.state.strings[0] = "192"
      row.state.hasLocalTextChanges = true
      row.state.onCommit()
      #expect(saved.count == 2)
      #expect(
        saved[1].translationX
          == Ldtx_Workspace_V4_Rational32.with {
            $0.num = 192
            $0.den = 1920
          })
      #expect(!row.state.hasLocalTextChanges)
    }

    @Test("UCT-1006.6: Positions require integer pixels while scales preserve decimals")
    func positionsRequireIntegerPixelsWhileScalesPreserveDecimals() throws {
      let fixture = VideoLayersTestFixture()
      var saved: Ldtx_Workspace_V4_BasicTransform?
      let table = fixture.makeTable()
      fixture.update(table, commit: { _, value in saved = value })
      let row = try #require(table.rows[1])
      for positions in [
        ["100.125", "0"], ["0", "1/3"],
      ] {
        row.state.strings = positions + ["1.25", "1"]
        row.state.hasLocalTextChanges = true
        row.state.onCommit()
        #expect(row.state.hasLocalTextChanges)
        #expect(Array(row.state.strings.prefix(2)) == positions)
      }
      for scale in ["7/9", "0.12345678901", "2147483648"] {
        row.state.strings = ["100", "1", scale, "1"]
        row.state.hasLocalTextChanges = true
        row.state.onCommit()
        #expect(row.state.hasLocalTextChanges)
        #expect(row.state.strings[2] == scale)
      }
      row.state.strings = ["100", "1", "1.25", "1"]
      row.state.onCommit()
      let transform = try #require(saved)
      #expect(transform.translationX.num == 100)
      #expect(transform.translationX.den == 1920)
      #expect(transform.translationY.num == 1)
      #expect(transform.translationY.den == 1080)
      #expect(transform.scaleX.num == 125)
      #expect(transform.scaleX.den == 100)
      #expect(row.state.strings == ["100", "1", "1.25", "1"])
    }

    @Test("Negative scales remain editable when changing position")
    func negativeScalesRemainEditable() throws {
      let fixture = VideoLayersTestFixture()
      var saved: Ldtx_Workspace_V4_BasicTransform?
      let table = fixture.makeTable()
      fixture.update(table, commit: { _, value in saved = value })
      let row = try #require(table.rows[1])
      row.state.strings = ["100", "1", "-1.25", "-0.5"]
      row.state.hasLocalTextChanges = true
      row.state.onCommit()
      let transform = try #require(saved)
      #expect(transform.scaleX.double == -1.25)
      #expect(transform.scaleY.double == -0.5)
      row.state.strings[0] = "200"
      row.state.hasLocalTextChanges = true
      row.state.onCommit()
      #expect(saved?.translationX.double == 200.0 / 1920.0)
      #expect(saved?.scaleX.double == -1.25)
      #expect(!row.state.hasLocalTextChanges)
    }

    @Test("UCT-1006.7: App kit commit requests read current draft once")
    func appKitCommitRequestsReadCurrentDraftOnce() throws {
      let fixture = VideoLayersTestFixture()
      var saved: [Ldtx_Workspace_V4_BasicTransform] = []
      let table = fixture.makeTable()
      fixture.update(table, commit: { _, value in saved.append(value) })
      let row = try #require(table.rows[1])
      row.state.strings = ["960", "270", "1.5", "2"]
      row.state.hasLocalTextChanges = true
      row.state.onCommit()
      row.state.onCommit()
      row.state.onCommit()
      #expect(saved.count == 1)
      #expect(
        saved.first?.translationX
          == Ldtx_Workspace_V4_Rational32.with {
            $0.num = 960
            $0.den = 1920
          })
      #expect(row.state.strings[0] == "960")

      row.state.strings[0] = "192"
      row.state.hasLocalTextChanges = true
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
      row.state.hasLocalTextChanges = true
      row.state.onCommit()
      fixture.update(table, ids: [3, 1, 2])
      #expect(table.rows[1] === row)
      #expect(row.state.strings[2] == value)
      #expect(fixture.reportedErrors.isEmpty)
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
      row.state.hasLocalTextChanges = true
      row.state.onCommit()
      #expect(
        fixture.reportedErrors.contains { $0.contains("Save failed.") })
      #expect(row.state.hasLocalTextChanges)
      #expect(row.state.strings[0] == "960")
      fixture.update(table)
      row.state.onCommit()
      #expect(!row.state.hasLocalTextChanges)
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
      _ = container.table.view(atColumn: 0, row: 1, makeIfNecessary: true)
      let laterRow = try #require(container.table.rows[2])
      laterRow.layoutSubtreeIfNeeded()
      laterRow.setFrameOrigin(NSPoint(x: 0, y: 40))
      for field in fixture.nativeFields(in: laterRow) {
        let point = field.convert(
          NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: laterRow.superview)
        #expect(laterRow.hitTest(point) != nil)
      }
      fixture.update(container.table, ids: [3, 2, 1])
      #expect(container.table.rows[1] === row)
      #expect(row.rootView.state === row.state)
    }

    @Test("UCT-1006.12: Hosted fields write on change without Enter")
    func hostedFieldsWriteOnChange() throws {
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
      #expect(saved.count == 1)
      #expect(row.state.strings[0] == "960")
      #expect(!row.state.hasLocalTextChanges)
      let secondEditor = try #require(fields[1].currentEditor() as? NSTextView)
      secondEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      #expect(saved.count == 1)
      #expect(
        saved.first?.translationX
          == Ldtx_Workspace_V4_Rational32.with {
            $0.num = 960
            $0.den = 1920
          })
      #expect(!row.state.hasLocalTextChanges)

      #expect(window.makeFirstResponder(fields[0]))
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      let nextEditor = try #require(fields[0].currentEditor() as? NSTextView)
      nextEditor.insertText(
        "480", replacementRange: NSRange(location: 0, length: nextEditor.string.utf16.count))
      #expect(window.makeFirstResponder(container.table))
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      #expect(saved.count == 2)
      #expect(!row.state.isEditing)
      #expect(!row.state.hasLocalTextChanges)
      let latest = try #require(saved.last)
      fixture.update(container.table, ids: [3, 2, 1], preferences: .with {
        $0.videoLayerTransforms[1] = latest
      })
      #expect(container.table.rows[1] === row)
      #expect(row.state.strings[0] == "480")
      container.table.removeAllRows()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      row.state.onCommit()
      #expect(saved.count == 2)
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
      let stateAppletData = WorkspaceAppletData()
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 1
      state.workspaceDefinition.programs = [program]
      state.workspacePreferences.landscapeProgramPreferences[1, default: .init()]
        .videoLayerInternalIds = [
          1, 2,
        ]
      var transform = Ldtx_Workspace_V4_BasicTransform()
      transform.scaleX = .with {
        $0.num = 1
        $0.den = 1
      }
      transform.scaleY = .with {
        $0.num = 1
        $0.den = 1
      }
      state.workspacePreferences.landscapeProgramPreferences[1, default: .init()]
        .videoLayerTransforms[1] =
        transform
      let content = VideoLayersEditor(
        stateService: state, appletData: stateAppletData,
        target: .landscape)
      content.refresh()
      let row = try #require(content.table.rows[1])
      state.workspacePreferences.landscapeProgramPreferences[1, default: .init()]
        .audioMasterVolumeDecibels = .with {
          $0.num = -9
          $0.den = 1
        }
      state.workspacePreferences.landscapeProgramPreferences[1, default: .init()]
        .videoLayerTransforms[
          1, default: .init()
        ].topInset = .with {
          $0.num = 1
          $0.den = 5
        }
      state.workspacePreferences.landscapeProgramPreferences[1, default: .init()].videoLayerHidden[
        2] = true
      row.state.strings[0] = "960"
      row.state.hasLocalTextChanges = true
      row.state.onCommit()
      let live = state.workspacePreferences.landscapeProgramPreferences[1] ?? .init()
      #expect(
        live.audioMasterVolumeDecibels
          == Ldtx_Workspace_V4_Rational32.with {
            $0.set(num: -9, den: 1)
          })
      #expect(
        live.videoLayerTransforms[1]?.topInset
          == Ldtx_Workspace_V4_Rational32.with {
            $0.num = 1
            $0.den = 5
          })
      #expect(
        live.videoLayerTransforms[1]?.translationX
          == Ldtx_Workspace_V4_Rational32.with {
            $0.num = 960
            $0.den = 1920
          })
      #expect(live.videoLayerHidden[2] == true)
      #expect(state.workspacePreferences.portraitProgramPreferences.isEmpty)
      #expect(row.state.strings[0] == "960")
    }

    @Test("Incomplete numeric input stays local without a navigation guard")
    func incompleteTransformInput() throws {
      let store = WorkspaceStateService(definition: .init(), preferences: .init())
      let editor = VideoLayersEditor(stateService: store, appletData: WorkspaceAppletData(), target: .landscape)
      editor.update(definition: .with { $0.videoComponents = [.with { $0.vfxSource.internalID = 1 }] },
        programPreferences: .init(), layerIDs: [1], canvasWidth: 1920, canvasHeight: 1080)
      let row = try #require(editor.table.rows[1])
      row.state.edit("-", at: 0)
      #expect(row.state.strings[0] == "-")
      store.inspectorSelector = .init(kind: .workspaceCanvas)
      #expect(store.inspectorSelector == .init(kind: .workspaceCanvas))
    }


    @Test("UCT-1006.15: Only VFX Sources and Clocks expose placement fields")
    func placementFieldsFollowComponentType() throws {
      let fixture = VideoLayersTestFixture()
      let editor = fixture.makeEditor()
      let components: [Ldtx_Workspace_V4_VideoComponentWrapper] = [
        .with { $0.vfxSource.internalID = 1 },
        .with { $0.clock.internalID = 2 },
        .with { $0.solidColorFill.internalID = 3 },
        .with { $0.linearGradientFill.internalID = 4 },
        .with { $0.radialGradientFill.internalID = 5 },
        .with { $0.conicGradientFill.internalID = 6 },
        .with { $0.testPattern.internalID = 7 },
      ]
      editor.update(
        definition: .with { $0.videoComponents = components },
        programPreferences: .init(), layerIDs: Array(1...7),
        canvasWidth: 1920, canvasHeight: 1080)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let container = NSView(frame: window.contentLayoutRect)
      window.contentView = container
      defer { window.close() }
      window.displayIfNeeded()
      for id in Int64(1)...7 {
        let row = try #require(editor.table.rows[id])
        row.frame = NSRect(x: 0, y: 0, width: 1000, height: 80)
        container.addSubview(row)
        row.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(row.state.supportsPlacement == (id <= 2))
        #expect(fixture.nativeFields(in: row).count == (id <= 2 ? 4 : 0))
        row.removeFromSuperview()
      }
    }

  }
}
