#!/bin/dash

# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

set -eu

export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

cd ..

XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
XCODEGEN_ARCHIVE=.xcodegen-${XCODEGEN_VERSION}.zip
XCODEGEN_DIRECTORY=.xcodegen

curl --fail --location --silent --show-error \
  --output "$XCODEGEN_ARCHIVE" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
echo "$XCODEGEN_SHA256  $XCODEGEN_ARCHIVE" | shasum -a 256 --check
rm -rf "$XCODEGEN_DIRECTORY"
unzip -q "$XCODEGEN_ARCHIVE" -d "$XCODEGEN_DIRECTORY"
rm "$XCODEGEN_ARCHIVE"

"$XCODEGEN_DIRECTORY/xcodegen/bin/xcodegen" generate
