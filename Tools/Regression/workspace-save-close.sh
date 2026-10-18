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
# Menu/key-equivalent target resolution requires an active, registered test app.
# Its unique bundle ID and LSHandlerRank=None keep it separate from LDTX.
menu_bundle="$probe_directory/CloseProbe.app"
mkdir -p "$menu_bundle/Contents/MacOS"
cp "$probe_directory/probe" "$menu_bundle/Contents/MacOS/probe"
probe_id=$(basename "$probe_directory" | tr -cd '[:alnum:]')
cat > "$menu_bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleIdentifier</key><string>tokyo.kaito.ldtx.regression.close.$probe_id</string>
<key>CFBundleName</key><string>LDTX Isolated Close Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSHandlerRank</key><string>None</string>
<key>LSItemContentTypes</key><array><string>public.plain-text</string></array>
</dict></array></dict></plist>
EOF
check_menu() {
  mode=$1
  protection=$2
  expected=$3
  result_file="$probe_directory/result.txt"
  rm -f "$result_file"
  : > "$probe_directory/menu.log"
  : > "$probe_directory/menu.err"
  open -n -F -W --stdout "$probe_directory/menu.log" --stderr "$probe_directory/menu.err" \
    --env "LDTX_SAVE_CLOSE_RESULT=$result_file" \
    --env "LDTX_SAVE_CLOSE_DESTINATION=$probe_directory/menu.txt" \
    "$menu_bundle" --args "$mode" "$protection"
  cat "$probe_directory/menu.log"
  [ -f "$result_file" ] && [ "$(cat "$result_file")" -eq "$expected" ]
}
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
  check_menu --menu-close --unprotected 99
  check_menu --key-close --unprotected 99
elif [ "${1:-}" = --menu ]; then
  check_menu --menu-close --protected 0
  check_menu --key-close --protected 0
elif [ "${1:-}" = --quit ]; then
  check_quit
else
  "$probe_directory/probe"
  "$probe_directory/probe" --repeated
  "$probe_directory/probe" --failure
  "$probe_directory/probe" --cancel-save-as
  "$probe_directory/probe" --retry
  check_quit
  check_menu --menu-close --protected 0
  check_menu --key-close --protected 0
fi
