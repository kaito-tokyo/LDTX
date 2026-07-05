#!/bin/dash

# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

cd ..

if [ "${CI_TAG+set}" = 'set' ] && [ "${CI_XCODEBUILD_EXIT_CODE:-}" = 0 ] && [ -n "${CI_ARCHIVE_PATH:=}" ]; then
  printf "Dispatching GitHub Actions release workflow for tag %s.\n" "$CI_TAG"
  ruby ci_scripts/dispatch_github_workflow.rb
fi
