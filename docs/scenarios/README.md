<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# UI Component Behavior Scenarios

Write behavior descriptions in English using Gherkin. Each file contains one
Feature and its Scenarios. These descriptions document expected behavior;
they do not execute tests or report test results.

## Corresponding component tests

Each Feature corresponds to exactly one test file and one child suite in
`Tests/LDTXAppUIComponentTests`. Each Scenario corresponds to exactly one test.
Include the Feature ID in the suite's display name and the Scenario ID in the
test's display name, for example `@Suite("UCT-1000: Workspace close confirmation")`
and `@Test("UCT-1000.1: Cancel closing preserves unsaved changes")`.

Organize tests around these behaviors rather than preserving old test-file
boundaries. Shared fixtures and helpers belong in separate support files;
they must not introduce additional behavior tests without a corresponding
Scenario. Keep the serialized MainActor parent suite for shared AppKit state.

## Filenames

Use `UCT-1000_PrimaryComponent_description.feature`, for example:

```text
UCT-1000_WorkspaceDocument_close-with-unsaved-changes.feature
```

The three parts are separated by underscores:

- Feature ID: start at `UCT-1000`, retain assigned IDs, and never reuse retired IDs.
- Primary component: exactly one component name, such as `WorkspaceDocument`.
- Description: a short English description in lowercase kebab-case.

## Tags

Place exactly two tags above the Feature: its case ID and the primary component
name from the filename.

Place one case ID above each Scenario, using the Feature ID followed by a dot
and a consecutive number starting at 1: `@UCT-1000.1`, `@UCT-1000.2`, and so on.
Do not use duplicate numbers, gaps, or leading zeros.

Scenarios may also have as many tags as needed for other involved components.
Do not repeat the primary component tag on a Scenario; it is inherited from
the Feature. Case ID tags belong only on Features and Scenarios.

```gherkin
@UCT-1000 @WorkspaceDocument
Feature: Workspace close confirmation with unsaved changes

  @UCT-1000.1 @WorkspaceWindowController
  Scenario: Cancel closing preserves unsaved changes
    Given a Workspace is open with unsaved changes
    When the user closes the Workspace and selects Cancel in the confirmation sheet
    Then the Workspace remains open
    And its unsaved changes are preserved
```

These conventions are maintained through authoring and review, without build-time
validation. See the [build guide](../build.md) for HTML generation.

Rendered case tags link to HTML anchors. For example, the first Scenario is
available at `scenarios/UCT-1000/#UCT-1000.1`.
