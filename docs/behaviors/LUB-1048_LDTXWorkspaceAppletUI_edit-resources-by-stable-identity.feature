# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1048 @LDTXWorkspaceAppletUI
Feature: edit resources by stable identity

  @LUB-1048.1 @UIComponent
  Scenario: Keep edits attached to their resource
    Given an editor for a selected resource identified by internal ID
    When resources are renamed, reordered, replaced, or removed
    Then edits still target that ID and stale callbacks cannot mutate another resource

  @LUB-1048.2 @UIComponent
  Scenario: Edit layers without changing unrelated content
    Given independent Program canvases with layer membership, order, visibility, and placement
    When an editable layer property is changed
    Then only the targeted Program canvas and layer change while other preferences are preserved

  @LUB-1048.3 @UIComponent
  Scenario: Delete only unreferenced editable components
    Given a component used by Program layers and possibly a Vision
    When deletion is requested
    Then Vision inputs must first be reassigned and accepted deletion clears that component's layer and timing references

  @LUB-1048.4 @UIComponent
  Scenario: Keep representable edits immediate and invalid drafts local
    Given a typed numeric field bound to a document value
    When input becomes representable or incomplete
    Then representable input is committed without Return while incomplete or out-of-range input preserves the last accepted value
