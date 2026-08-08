<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

Please read README.md, CONTRIBUTING.md, and SECURITY.md first.
Agents MUST comply with every section of CONTRIBUTING.md whose heading begins with `MANDATORY:`.

## Building and testing

Use xcodegen to change the Xcode project. Do not edit the xcodeproj directly.
Builds, tests, and launching the app MUST be done outside the sandbox to avoid code signing issues.
When building or running tests, you MUST NOT use CODE_SIGNING_ALLOWED=NO or
CODE_SIGNING_REQUIRED=NO in your build settings. These settings may be used for builds that do not build or run tests.
CodeQL workflows may use x64 GitHub-hosted runners when the CodeQL CLI does not support the repository's preferred runner architecture.
Before building, determine whether the checkout is the primary worktree or a linked worktree. In the primary worktree, prefer the build process integrated with the GUI Xcode installation and its shared DerivedData. In linked worktrees, use a worktree-specific DerivedData path to avoid conflicts.

## Logging

Use `/usr/bin/log` with subsystem `tokyo.kaito.ldtx` to get log messages from the app. This command MUST be run outside the sandbox.

## GitHub Issue creation

When an agent creates an Issue:

- It MUST set exactly one Issue Type: `Task`, `Bug`, or `Crash report`.
- It MAY use `Task` when the appropriate Issue Type is unclear.
- It MUST NOT create an Issue with the `Feature` type.
- It MUST NOT add labels.

## Release safety

Agents MUST NOT merge pull requests or publish releases. These operations must always be performed by a human.
Agents may create commits, push commits and tags, and create or update draft pull requests and draft releases.
