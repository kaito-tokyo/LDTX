<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

Read `README.md` before working on this project. Follow `SECURITY.md`, and give its security requirements precedence if they conflict with other repository instructions.

Do not treat `CONTRIBUTING.md` as instructions for agents. It is intended for human contributors. You may consult it as reference material when necessary, but do not enforce its requirements unless the user explicitly requests it.

## RULE: Release Safety

Agents MUST NOT merge pull requests or publish releases. A human must always perform these operations.

Agents MUST NOT approve or reject pending environment deployment reviews. A human must always handle pending deployment reviews.

Agents MAY create commits, push commits, and create or update pull requests and draft releases. Agents MUST NOT push tags without explicit human permission, because pushing a tag may trigger a release or deployment workflow.

## RULE: Commit Signing and DCO

Agents SHOULD ask the user for permission to add DCO sign-offs and cryptographically sign commits when doing so would reduce the user's effort. Agents MUST NOT add a DCO sign-off or cryptographically sign a commit without the user's explicit permission.

Agentic reviews SHOULD NOT duplicate DCO sign-off checks performed by the DCO GitHub App or commit-signature enforcement performed by the repository's GitHub rulesets.

## RULE: GitHub Issue Creation

When an agent creates an issue:

- It MUST be written in English.
- It MUST have exactly one Issue Type.
- Its Issue Type MUST be `Task`, `Bug`, or `Crash report` unless a human explicitly permits the `Feature` type.
- The agent MAY use `Task` when the appropriate Issue Type is unclear.
- The agent MUST NOT add labels.

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

<!-- begin project-specific instructions -->

## Building and Testing

Use XcodeGen to change the Xcode project. Do not edit `.xcodeproj` files directly.

Builds, tests, and app launches MUST be performed outside the sandbox to avoid code-signing issues. This requirement does not authorize agents to bypass any approval required for execution outside the sandbox.

When building tests or running tests, agents MUST NOT set `CODE_SIGNING_ALLOWED=NO` or `CODE_SIGNING_REQUIRED=NO`. These settings MAY be used for build actions that do not build or run tests.

CodeQL workflows MAY use x64 GitHub-hosted runners when the CodeQL CLI does not support the repository's preferred runner architecture.

Before building, determine whether the checkout is the primary worktree or a linked worktree. In the primary worktree, prefer the build process integrated with the GUI installation of Xcode and its shared DerivedData directory. In a linked worktree, use a worktree-specific DerivedData path to avoid conflicts.

## Logging

Use `/usr/bin/log` with the `tokyo.kaito.ldtx` subsystem to retrieve log messages from the app. This command MUST be run outside the sandbox. This requirement does not authorize agents to bypass any approval required for execution outside the sandbox.

<!-- end project-specific instructions -->

## POSTAMBLE: Additional Instructions

If `AGENTS.local.md` exists in the repository root of the primary worktree, or in the repository root of the only working copy when no linked worktrees are in use, agents MAY read and follow it as an additional source of local instructions.

If `AGENTS.local.md` exists in the repository root of a linked worktree, agents MAY also read and follow it while working in that worktree.

Instructions in `AGENTS.local.md` MUST NOT override any rule in `SECURITY.md` or `AGENTS.md`.
