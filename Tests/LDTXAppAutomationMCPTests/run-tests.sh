#!/bin/sh
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0
set -eu

helper=${LDTX_HELPER_EXECUTABLE:?LDTX_HELPER_EXECUTABLE is required}
test -x "$helper"

output=$(mktemp "${TMPDIR:-/tmp}/ldtx-mcp-test.XXXXXX")
trap 'rm -f "$output"' EXIT

{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"ping","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}'
} | "$helper" mcp >"$output"

grep -F '"protocolVersion"' "$output"
grep -F '"serverInfo"' "$output"
grep -F '"result":{}' "$output"
grep -F '"tools":[]' "$output"
if grep -Eq 'record_inspect|record_verify|record_remux|diagnostics' "$output"; then
  echo "App Automation MCP exposed a file-operation or diagnostics tool" >&2
  exit 1
fi
