<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

Please read README.md and CONTRIBUTING.md first.

## Building and testing

Use xcodegen to change the Xcode project. Do not edit the xcodeproj directly.
Use .derivedData for -derivedDataPath to avoid conflicts with user's Xcode.
Builds, tests, and launching the app MUST be done outside the sandbox to avoid code signing issues.
You MUST NOT use CODE_SIGNING_ALLOWED=NO or CODE_SIGNING_REQUIRED=NO in your build settings.

## Logging

Use `/usr/bin/log` with subsystem `tokyo.kaito.ldtx` to get log messages from the app. This command MUST be run outside the sandbox.

## Release safety

Agents MUST NOT merge pull requests or publish releases. These operations must always be performed by a human.
Agents may create commits, push commits and tags, and create or update draft pull requests and draft releases.
