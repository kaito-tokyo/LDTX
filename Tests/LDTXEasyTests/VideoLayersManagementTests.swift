// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
@testable import LDTXWorkspaceAppletUI
import Testing

@Suite
struct VideoLayersManagementUnitTestSuite {
  let options: [WorkspaceSelectionOption<UInt64>] = [
    .init(id: 1, name: "One"), .init(id: 2, name: "Two"), .init(id: 3, name: "Three"),
  ]

  @Test func membershipDraftDoesNotChangeSourceAndRejectsDuplicates() {
    let source: [UInt64] = [1, 2]
    var draft = VideoLayersManagementDraft(ids: source, options: options)
    #expect(!draft.canApply(currentIDs: source, options: options, active: false))
    draft.remove(1)
    draft.add(1)
    #expect(draft.ids == source)
    #expect(!draft.canApply(currentIDs: source, options: options, active: false))
    draft.add(1)
    draft.add(999)
    #expect(draft.ids == source)
    draft.remove(1)
    draft.add(3)
    #expect(draft.ids == [2, 3])
    #expect(source == [1, 2])
    #expect(draft.originalIDs == source)
    #expect(draft.canApply(currentIDs: source, options: options, active: false))
    #expect(!draft.canApply(currentIDs: source, options: options, active: true))
    #expect(!draft.canApply(currentIDs: [2, 1], options: options, active: false))
    #expect(!draft.canApply(currentIDs: source, options: Array(options.dropLast()), active: false))
    let reopened = VideoLayersManagementDraft(ids: source, options: options)
    #expect(reopened.ids == source)
  }
}

extension VideoLayersManagementUnitTestSuite {
  @Test func applyCommitsOnceAndFailureRetainsDraft() throws {
    var draft = VideoLayersManagementDraft(ids: [1], options: options)
    draft.add(2)
    var calls = 0
    #expect(throws: WorkspaceSelectionError.self) {
      try draft.apply(currentIDs: [1], options: options, active: false) { _, _, _ in
        calls += 1
        throw WorkspaceSelectionError(message: "Failed")
      }
    }
    #expect(draft.ids == [1, 2])
    try draft.apply(currentIDs: [1], options: options, active: false) { ids, baseline, candidates in
      calls += 1
      #expect(ids == [1, 2])
      #expect(baseline == [1])
      #expect(candidates == options)
    }
    #expect(calls == 2)
    #expect(throws: WorkspaceSelectionError.self) {
      try draft.apply(currentIDs: [1], options: options, active: true) { _, _, _ in calls += 1 }
    }
    #expect(calls == 2)
  }
}
