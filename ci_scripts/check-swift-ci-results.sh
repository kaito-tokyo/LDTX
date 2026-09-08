#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

for result in "$@"; do
  if [[ "$result" != success ]]; then
    printf 'Required Swift CI job did not succeed: %s\n' "$result" >&2
    exit 1
  fi
done
