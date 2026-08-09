#!/bin/dash

# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

set -eu

# Xcode Cloud can validate SwiftPM build tool plugins while preparing package
# dependencies. mlx-swift includes the CudaBuild plugin, so allow package
# plugins before dependency resolution and project generation begin.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES

export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

cd ..

brew install xcodegen
xcodegen generate
