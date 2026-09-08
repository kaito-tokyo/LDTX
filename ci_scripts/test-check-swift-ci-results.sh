#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

bash "$script_dir/check-swift-ci-results.sh" success success success
if bash "$script_dir/check-swift-ci-results.sh" success failure success; then
  exit 1
fi
if bash "$script_dir/check-swift-ci-results.sh" success cancelled success; then
  exit 1
fi
