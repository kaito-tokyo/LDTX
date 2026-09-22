#!/bin/sh
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
# SPDX-License-Identifier: Apache-2.0
set -eu

ldtx=${LDTX_CLI_EXECUTABLE:-.build/arm64-apple-macosx/release/ldtx}
output_dir=$(mktemp -d "${TMPDIR:-/tmp}/ldtx-cli-tests.XXXXXX")
trap 'rm -rf "$output_dir"' EXIT

test -x "$ldtx"

help_output=$("$ldtx" --help)
printf '%s\n' "$help_output" | grep -F 'Inspect, verify, and remux LDTX recording packages'
printf '%s\n' "$help_output" | grep -F 'record'
printf '%s\n' "$help_output" | grep -F 'workspace'
if printf '%s\n' "$help_output" | grep -Eq '(^|[[:space:]])(app|mcp|diagnostics)([[:space:]]|$)'; then
  echo "standalone ldtx exposes an app-only command" >&2
  exit 1
fi

for command in \
  'record inspect' \
  'record verify' \
  'record remux' \
  'workspace create' \
  'workspace dump' \
  'workspace validate'
do
  command_help=$($ldtx $command --help)
  printf '%s\n' "$command_help" | grep -F -- '--help'
done

missing_path="$output_dir/does-not-exist"
if "$ldtx" record inspect "$missing_path" >/dev/null 2>&1; then
  echo "record inspect unexpectedly accepted a missing package" >&2
  exit 1
fi
if "$ldtx" workspace validate "$missing_path" >/dev/null 2>&1; then
  echo "workspace validate unexpectedly accepted a missing package" >&2
  exit 1
fi
