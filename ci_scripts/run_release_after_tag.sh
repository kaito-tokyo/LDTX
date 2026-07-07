#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run_release_after_tag.sh [--background] [--interval seconds] [--watch-interval seconds] <tag>

Wait for Xcode Cloud's notarized artifact for <tag>, dispatch release.yml for that tag,
and wait for the GitHub Actions run to finish.

Examples:
  ./ci_scripts/run_release_after_tag.sh v0.1.4
  ./ci_scripts/run_release_after_tag.sh --background v0.1.4

Environment:
  APP_STORE_CONNECT_ISSUER
  APP_STORE_CONNECT_KEY_ID
  APP_STORE_CONNECT_KEY_BASE64
  GH_TOKEN (or an authenticated gh session)
EOF
}

background=0
forwarded_args=()

while (($# > 0)); do
  case "$1" in
    --background)
      background=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      forwarded_args+=("$1")
      ;;
  esac
  shift
done

watch_directory="${RELEASE_WATCH_DIR:-.derivedData/release-watch}"
mkdir -p "$watch_directory"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

if [[ $background -eq 1 ]]; then
  tag_name='release'
  if ((${#forwarded_args[@]} > 0)); then
    last_index=$((${#forwarded_args[@]} - 1))
    tag_name="${forwarded_args[$last_index]}"
  fi
  log_path="$watch_directory/${tag_name}-${timestamp}.log"
  status_path="$watch_directory/${tag_name}-${timestamp}.status"
  nohup env STATUS_PATH="$status_path" \
    node ./ci_scripts/run_release_after_tag.mjs "${forwarded_args[@]}" \
    >"$log_path" 2>&1 </dev/null &
  printf 'Started background release watcher for %s.\n' "$tag_name"
  printf 'pid=%s\n' "$!"
  printf 'log=%s\n' "$log_path"
  printf 'status=%s\n' "$status_path"
  exit 0
fi

exec node ./ci_scripts/run_release_after_tag.mjs "${forwarded_args[@]}"
