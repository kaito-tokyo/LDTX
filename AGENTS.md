<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

- [RULE: Release Safety](#rule-release-safety)
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
straightforward. Easy, Medium, and Hard are execution cost and resource tiers
used in part to keep each routine test run within its configured limits.
Classify a test by the most demanding resource or execution property it
naturally needs; a test may belong to a higher tier than its logic alone would
suggest.

- **EasyTests target:** Pure logic tests that are short, deterministic, and
  runnable in a strict sandbox without relying on external resources.
- **MediumTests target:** Tests that remain predictable and modest in cost but
  naturally use a safe external resource, such as a temporary directory, a
  local database, or a controlled subprocess. Prefer Medium when the resource
  makes the test more representative, even if an in-memory Easy equivalent is
  possible. This tier also helps keep routine Easy runs within their limits.
- **HardTests target:** Tests with substantial computation or media work, long
  execution, or dependencies on hardware, drivers, external services, or other
  demanding environments. A test is Hard when it has such requirements even if
  it is individually short. The project-wide requirement to launch builds and
  tests outside the sandbox does not by itself make a test Hard.
- **UnitTestSuite:** Tests of one SUT in isolation, with no special setup,
  execution control, or shared-state coordination needed.
- **IntegrationTestSuite:** Tests involving multiple components or other
  conditions that require deliberate setup or attention during execution.
- **SystemTests target:** Tests whose dependencies, shared state, or execution
  requirements are too entangled to be safely organized as ordinary Easy or
  Hard tests. Isolate these in SystemTests targets named for the SUT, so each
  target can be run and coordinated independently.
- **XpcTests target:** XPC tests are a special case of System tests because
  interprocess communication requires an isolated execution boundary. Use the
  `XpcTests` target name for this execution unit; the name does not need to
  include `System`.

Use suite names to express Unit or Integration scope within EasyTests,
MediumTests, and HardTests targets. Do not use `SystemTestSuite` merely as a
synonym for `@Suite(.serialized)`; a SystemTests target is an isolation boundary
for a specific SUT. Keep Xcode application-lifecycle and interprocess
integration tests focused on startup and minimal service communication. Put
substantial media processing in the owning module's HardTests target.
