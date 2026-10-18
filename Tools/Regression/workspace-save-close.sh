#!/bin/sh
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
# SPDX-License-Identifier: Apache-2.0
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
probe_directory=$(mktemp -d "${TMPDIR:-/tmp}/ldtx-save-close.XXXXXX")
trap 'rm -rf "$probe_directory"' EXIT HUP INT TERM
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$probe_directory/cache" \
  "$repository/Sources/Applets/Workspace/WorkspaceDocumentCloseCoordinator.swift" \
  "$repository/Sources/Applets/Workspace/WorkspaceApplication.swift" \
  "$repository/Tools/Regression/WorkspaceSaveClose.swift" \
  -o "$probe_directory/probe"
check_quit() {
  LDTX_SAVE_CLOSE_DESTINATION="$probe_directory/quit.txt" "$probe_directory/probe" --quit
  [ "$(cat "$probe_directory/quit.txt")" = latest ]
  LDTX_SAVE_CLOSE_DESTINATION="$probe_directory/multiple.txt" "$probe_directory/probe" --quit --multiple
  [ "$(cat "$probe_directory/multiple.txt")" = latest ]
  [ "$(cat "$probe_directory/multiple.second.txt")" = 'second latest' ]
  "$probe_directory/probe" --quit-cancel
  "$probe_directory/probe" --quit-failure
}
if [ "${1:-}" = --baseline ]; then
  # All three paths must reproduce the original deadlock, bounded by the watchdog.
  for mode in --single --repeated --quit; do
    result=0
    "$probe_directory/probe" --unprotected "$mode" || result=$?
    [ "$result" -eq 99 ] || exit 1
  done
elif [ "${1:-}" = --quit ]; then
  check_quit
else
  "$probe_directory/probe"
  "$probe_directory/probe" --repeated
  "$probe_directory/probe" --failure
  "$probe_directory/probe" --cancel-save-as
  "$probe_directory/probe" --retry
  check_quit
fi
