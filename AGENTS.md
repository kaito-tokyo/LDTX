<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

Please read README.md and CONTRIBUTING.md first.
Use xcodegen to change the Xcode project. Do not edit the xcodeproj directly.
Use .derivedData for -derivedDataPath to avoid conflicts with user's Xcode.
Run `swift build`, `swift test`, or xcodebuild commands outside the sandbox.
