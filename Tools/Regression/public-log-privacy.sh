#!/bin/sh
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
# SPDX-License-Identifier: Apache-2.0
set -eu
# Build the focused Xcode tests first. Run this script outside the agent sandbox,
# as required by AGENTS.md for /usr/bin/log. It does not change logging settings.
repository=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
products=${1:-"$repository/.derivedData/Build/Products/Debug"}
probe_directory=$(mktemp -d "${TMPDIR:-/tmp}/ldtx-log-privacy.XXXXXX")
trap 'rm -rf "$probe_directory"' EXIT HUP INT TERM
generated_headers=$repository/Packages/LDTXCorelibs/Sources/LDTXNanopbGenerated/include
cat > "$probe_directory/nanopb.modulemap" <<EOF
module nanopb {
  umbrella "$repository/Packages/LDTXCorelibs/Sources/nanopb/include"
  export *
}
EOF
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$probe_directory/cache" -F "$products" -F "$products/PackageFrameworks" -I "$products" \
  -Xcc -fmodule-map-file="$generated_headers/module.modulemap" \
  -Xcc -fmodule-map-file="$probe_directory/nanopb.modulemap" \
  -Xcc -I"$repository/Packages/LDTXCorelibs/Sources/nanopb/include" \
  -framework LDTXDash -framework LDTXCorelibs -framework LDTXProgramRuntime \
  -Xlinker -rpath -Xlinker "$products" \
  -Xlinker -rpath -Xlinker "$products/PackageFrameworks" \
  "$repository/Tools/Regression/PublicLogPrivacy.swift" -o "$probe_directory/probe"
# Xcode test runners can enable private logging. Use an ordinary process here.
probe_output=$(env -u OS_ACTIVITY_DT_MODE "$probe_directory/probe")
probe_pid=${probe_output##*=}
case "$probe_pid" in ''|*[!0-9]*) echo 'Missing probe PID' >&2; exit 1 ;; esac
/usr/bin/log show --last 1m --style json \
  --predicate "subsystem == \"tokyo.kaito.ldtx\" AND processID == $probe_pid" \
  > "$probe_directory/log.json"
python3 - "$probe_directory/log.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    messages = [entry.get("eventMessage", "") for entry in json.load(source)]
assert any("discardedCount=1" in message for message in messages), "Missing normalization event"
assert any(
    "DASH PUT transport failure" in message and "code=220" in message
    for message in messages
), "Missing transport error event/code"
assert not any("ISSUE220_PRIVATE_" in message for message in messages), "Private fixture exposed"
print("PASS: production events and numeric diagnostics collected; private fixtures absent")
PY
