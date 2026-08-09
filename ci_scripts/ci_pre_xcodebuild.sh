#!/bin/dash

# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

# Xcode Cloud cannot pass -skipPackagePluginValidation to xcodebuild. Package.swift pins mlx-swift and Package.resolved records the reviewed revision, so allow its CudaBuild plugin before archive starts.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES
