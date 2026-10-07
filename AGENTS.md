<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

- [RULE: Release Safety](#rule-release-safety)
- [RULE: Fixed Workspace Versions](#rule-fixed-workspace-versions)
- [RULE: Commit Signing and DCO](#rule-commit-signing-and-dco)
- [RULE: Commit Messages](#rule-commit-messages)
- [RULE: GitHub Pull Request Body](#rule-github-pull-request-body)
- [RULE: GitHub Issue Creation](#rule-github-issue-creation)
- [PRJ: Design Principles](#prj-design-principles)
- [PRJ: Logging](#prj-logging)
- [PRJ: Test classification](#prj-test-classification)

# AGENTS.md

Read `README.md` before working on this project. Follow `SECURITY.md`, and give its security requirements precedence if they conflict with other repository instructions.

Do not treat `CONTRIBUTING.md` as instructions for agents. It is intended for human contributors. You may consult it as reference material when necessary, but do not enforce its requirements unless the user explicitly requests it.

## RULE: Release Safety

Agents MUST NOT merge pull requests or publish releases. A human must always perform these operations.

Agents MUST NOT approve or reject pending environment deployment reviews. A human must always handle pending deployment reviews.

Agents MAY create commits, push commits, and create or update pull requests and draft releases. Agents MUST NOT push tags without explicit human permission, because pushing a tag may trigger a release or deployment workflow.

## RULE: Fixed Workspace Versions

Workspace Version (`LDTXWorkspaceVersion`) MUST remain the integer `4`. Workspace Bundle Version (`LDTXWorkspaceBundleVersion`) MUST remain the string `4.0`.

This is an absolute rule. Agents MUST NOT change either version, regardless of schema changes, compatibility concerns, or implementation requirements. Agents MUST NOT amend, remove, or bypass this rule to permit a version change. If a version change is required, a human must first change this rule in `AGENTS.md`; only then may agents implement the versions specified by the human's revised rule.

## RULE: Commit Signing and DCO

Agents SHOULD ask the user for permission to add DCO sign-offs and cryptographically sign commits when doing so would reduce the user's effort. Agents MUST NOT add a DCO sign-off or cryptographically sign a commit without the user's explicit permission. Agents SHOULD decline to commit if they don't have DCO and signing permissions.

Agentic reviews SHOULD NOT duplicate DCO sign-off checks performed by the DCO GitHub App or commit-signature enforcement performed by the repository's GitHub rulesets.

## RULE: Commit Messages

When creating a commit, follow these rules:

- Write the commit title in the imperative mood and keep it within 50 characters whenever possible.
- Do not add prefixes such as `feat:`, `fix:`, or `chore:` to the title.
- Insert a blank line between the title and body.
- Describe the changes in the body using complete sentences.
- Use a separate paragraph for each logical unit of change, with a blank line between paragraphs.
- If the user has explicitly authorized a DCO sign-off, use the `git commit -s` option.
- If the user has explicitly authorized cryptographic signing, sign the commit using the configured Git signing method.
- Before committing, verify that the message accurately describes only the staged changes.

## RULE: GitHub Pull Request Body

The body of a pull request consists of three parts in this order:

1. A brief description paragraph, written in complete sentences and describing only the changes contained in the pull request. Do not put a heading above it.
2. An `## Overview` section. Its format is free: any prose, list, or generated summary (such as GitHub Copilot's Summary) is acceptable as long as it explains the change.
3. The following Pull Request Checklist. GitHub inserts `.github/pull_request_template.md` here automatically when the pull request is created interactively. When an agent creates a pull request through a path that does not insert it (for example `gh pr create --body`), the agent MUST emulate that behavior: append the file's contents verbatim as the last part of the body. Agents MUST NOT modify the checklist and MUST leave every checkbox unchecked, because its items are first-person statements by the human author.

Do not add labels, reviewers, or assignees unless the user explicitly requests it.

```markdown
## Pull Request Checklist

Please read our latest [CONTRIBUTING.md](https://github.com/kaito-tokyo/LDTX/blob/main/CONTRIBUTING.md).

- [ ] I have read the latest CONTRIBUTING.md.
- [ ] I have signed off and verified all my commits.
```

## RULE: GitHub Issue Creation

When an agent creates an issue:

- It MUST be written in English.
- Its title MUST begin with exactly one of these prefixes: `[BUG]`, `[FEATURE]`, `[TASK]`, or `[CRASH REPORT]`.
- The agent MUST NOT add labels.

## PRJ: Design Principles

Cross-cutting design principles are maintained in [`docs/design-principles.md`](docs/design-principles.md). Treat that document as the source of truth for implementation, tests, and reviews involving those principles. Other documentation may be consulted at the agent's discretion when relevant.

## PRJ: Logging

Use `/usr/bin/log` with the `tokyo.kaito.ldtx` subsystem to retrieve log messages from the app. This command MUST be run outside the sandbox. This requirement does not authorize agents to bypass any approval required for execution outside the sandbox.

## PRJ: Test classification

This classification applies to XcodeGen-managed tests. SwiftPM-managed tests
are out of scope for this classification rule; they use Swift Testing and
belong to their corresponding module. Keep the test target structure
straightforward. Easy, Medium, and Hard classify tests by their dependencies.
The framework lists below are project conventions, not a general measure of
hardware dependence or test difficulty. Computational cost, sandbox permissions,
and CI availability do not determine the tier. Decide where each target runs
in CI separately from its classification.

- **EasyTests target:** Pure logic tests without platform-framework execution
  dependencies.
- **MediumTests target:** Tests that depend on macOS APIs, including
  **CoreGraphics**, **CoreAudio**, **AudioToolbox**, **CoreMedia**, **CoreVideo**,
  and **CoreImage**, plus non-View **SwiftUI** value APIs, unless they exercise a
  framework listed under HardTests.
- **HardTests target:** Tests that exercise **Vision**, **VideoToolbox**,
  **CoreML**, **Metal**, or **AVFoundation**. Medium and Hard tests may have the
  same Unit or Integration scope; their framework dependencies distinguish them.
  Run this hostless unit-test target directly in Xcode Cloud; do not add XCUI
  automation.

For tests outside OutputTests, classify the APIs exercised by the test and its SUT,
not merely import statements or unrelated transitive dependencies. A test
that exercises both Medium and Hard frameworks belongs in HardTests. For an
unlisted framework, make an explicit project decision and update these lists
rather than inferring its tier from hardware use or CI behavior.

- **OutputTests target:** Output configuration, recording and streaming output
  sessions, media delivery, output timing/encoding, and output protocol tests
  belong in the macOS-only,
  hostless `LDTXOutputTests` target regardless of the Easy, Medium, or Hard
  frameworks they exercise. Group them under the serialized OutputTestSuite
  parent, including the AVAssetWriter lifecycle parent and its child suites.
  Playback/verification and marker editing keep their respective framework or
  component targets. Corelibs bundle IO remains in CorelibsTests. Keep XPC
  process isolation tests in XpcTests.
- **CorelibsTests target:** Shared Linux-compatible module tests under
  `Tests/Corelibs` belong in `LDTXCorelibsTests` for both XcodeGen and SwiftPM.
  This target may contain deterministic unit tests and filesystem integration
  tests; keep their Unit or Integration scope in suite names.
- **UnitTestSuite:** Tests of one SUT in isolation, with no special setup,
  execution control, or shared-state coordination needed.
- **IntegrationTestSuite:** Tests involving multiple components or other
  conditions that require deliberate setup or attention during execution.
- **UIComponentTests target:** Directly constructed UI components and Documents,
  including their Window and Sheet behavior, belong in the hostless
  `LDTXAppUIComponentTests` target. Coordinate shared AppKit state through its
  serialized MainActor parent suite.
- **UITests target:** Operations on the launched application through UI automation
  belong in `LDTXAppUITests`. Keep automation focused on launch and main-menu
  wiring; prefer component tests for document and window behavior.
  Only `LDTXAppUITests` may use XCUI; it launches the app under test separately.
  Only XpcTests may use a host application (`TEST_HOST` or `BUNDLE_LOADER`).
- **SystemTests target:** Use a SUT-specific target only when a concrete process
  isolation requirement prevents safe execution in the shared component target.
  Window or Document usage alone does not require a separate target.
- **XpcTests target:** XPC tests are a special case of System tests because
  interprocess communication requires an isolated execution boundary. Use the
  `XpcTests` target name for this execution unit; the name does not need to
  include `System`.
  XpcTests may launch a host application to exercise its embedded XPC service.

Use suite names to express Unit or Integration scope within EasyTests,
MediumTests, and HardTests targets. Do not use `SystemTestSuite` merely as a
synonym for `@Suite(.serialized)`; a SystemTests target is an isolation boundary
for a specific SUT. Keep Xcode application-lifecycle and interprocess
integration tests focused on startup and minimal service communication.
Classify media-processing tests using the framework lists above.
