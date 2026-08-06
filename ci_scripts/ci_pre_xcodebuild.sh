#!/bin/dash

# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

# Xcode Cloud does not provide a workflow setting for passing -skipPackagePluginValidation to xcodebuild. mlx-swift includes the CudaBuild SwiftPM build tool plugin, so allow package plugins before archive starts. Package.swift declares exact MLX versions and Package.resolved records their reviewed revisions; changing either is security-sensitive.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES
