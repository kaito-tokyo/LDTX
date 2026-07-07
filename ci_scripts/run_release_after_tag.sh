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

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

write_status() {
  local value="$1"
  if [[ -n "${STATUS_PATH:-}" ]]; then
    printf '%s\n' "$value" >"$STATUS_PATH"
  fi
}

background=0
poll_interval=30
watch_interval=10
tag_name=""

while (($# > 0)); do
  case "$1" in
    --background)
      background=1
      ;;
    --interval)
      poll_interval="${2:?missing value for --interval}"
      shift
      ;;
    --watch-interval)
      watch_interval="${2:?missing value for --watch-interval}"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 64
      ;;
    *)
      if [[ -n "$tag_name" ]]; then
        printf 'Unexpected argument: %s\n' "$1" >&2
        usage >&2
        exit 64
      fi
      tag_name="$1"
      ;;
  esac
  shift
done

if [[ -z "$tag_name" ]]; then
  usage >&2
  exit 64
fi

if [[ ! "$tag_name" =~ ^v[0-9A-Za-z.+-]+$ ]]; then
  printf 'Tag must start with v and contain only SemVer characters: %s\n' "$tag_name" >&2
  exit 64
fi

if ! git rev-parse -q --verify "refs/tags/$tag_name" >/dev/null; then
  printf 'Local tag not found: %s\n' "$tag_name" >&2
  exit 66
fi

watch_directory="${RELEASE_WATCH_DIR:-.derivedData/release-watch}"
mkdir -p "$watch_directory"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

if [[ $background -eq 1 ]]; then
  log_path="$watch_directory/${tag_name}-${timestamp}.log"
  status_path="$watch_directory/${tag_name}-${timestamp}.status"
  nohup env STATUS_PATH="$status_path" \
    "$0" --interval "$poll_interval" --watch-interval "$watch_interval" "$tag_name" \
    >"$log_path" 2>&1 </dev/null &
  printf 'Started background release watcher for %s.\n' "$tag_name"
  printf 'pid=%s\n' "$!"
  printf 'log=%s\n' "$log_path"
  printf 'status=%s\n' "$status_path"
  exit 0
fi

current_status='starting'
trap '
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    write_status "failed:${current_status}"
    log "Release watcher failed during ${current_status}"
  fi
' EXIT

write_status 'waiting-xcode-cloud'
current_status='waiting-xcode-cloud'
log "Waiting for Xcode Cloud notarized artifact for ${tag_name}"
node ./ci_scripts/wait_for_xcode_cloud_notarized.mjs "$tag_name" --interval "$poll_interval"

tag_sha="$(git rev-list -n 1 "$tag_name")"
dispatched_after="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_status 'dispatching-release-workflow'
current_status='dispatching-release-workflow'
log "Dispatching release.yml for ${tag_name}"
gh workflow run release.yml --ref "$tag_name"

write_status 'waiting-github-actions-run'
current_status='waiting-github-actions-run'
log "Locating release.yml run for ${tag_name}"

run_metadata=''
for _ in $(seq 1 30); do
  run_json="$(
    gh run list \
      --workflow release.yml \
      --event workflow_dispatch \
      --json databaseId,createdAt,displayTitle,headBranch,headSha,url \
      --limit 20
  )"
  run_metadata="$(
    RUN_JSON="$run_json" \
    TAG_NAME="$tag_name" \
    TAG_SHA="$tag_sha" \
    DISPATCHED_AFTER="$dispatched_after" \
    ruby -rjson -rtime -e '
      runs = JSON.parse(ENV.fetch("RUN_JSON"))
      cutoff = Time.iso8601(ENV.fetch("DISPATCHED_AFTER"))
      selected = runs
        .select do |run|
          run["headSha"] == ENV.fetch("TAG_SHA") &&
            Time.iso8601(run.fetch("createdAt")) >= cutoff &&
            (run["headBranch"] == ENV.fetch("TAG_NAME") || run.fetch("displayTitle", "").include?(ENV.fetch("TAG_NAME")))
        end
        .max_by { |run| Time.iso8601(run.fetch("createdAt")) }
      if selected
        puts [selected.fetch("databaseId"), selected.fetch("url", "")].join("\t")
      end
    '
  )"
  if [[ -n "$run_metadata" ]]; then
    break
  fi
  sleep "$watch_interval"
done

if [[ -z "$run_metadata" ]]; then
  printf 'Could not find the dispatched release.yml run for %s.\n' "$tag_name" >&2
  exit 69
fi

run_id="${run_metadata%%$'\t'*}"
run_url="${run_metadata#*$'\t'}"
log "Watching GitHub Actions run ${run_id}${run_url:+ (${run_url})}"
gh run watch "$run_id" --compact --exit-status --interval "$watch_interval"

write_status 'completed'
current_status='completed'
log "Release workflow completed successfully for ${tag_name}"
