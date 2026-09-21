#!/bin/sh
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
# SPDX-License-Identifier: Apache-2.0
set -eu

helper=${LDTX_HELPER_EXECUTABLE:-.derivedData/Build/Products/Debug/LDTXHelper}
output_dir=$(mktemp -d "${TMPDIR:-/tmp}/ldtx-cli-tests.XXXXXX")
trap 'rm -rf "$output_dir"' EXIT

test -x "$helper"

help_output=$("$helper" --help)
printf '%s\n' "$help_output" | grep -F 'Inspect, verify, and remux LDTX recording packages'
printf '%s\n' "$help_output" | grep -F 'diagnostics'

if "$helper" diagnostics samples \
  --start 2026-07-27T00:00:01Z \
  --end 2026-07-27T00:00:00Z \
  >"$output_dir/stdout" 2>"$output_dir/stderr"; then
  echo 'expected diagnostics command to reject a reversed range' >&2
  exit 1
fi

grep -F 'start time must be earlier than the end time' "$output_dir/stderr"
