#!/usr/bin/env node

// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import { gitTagSHA, hasLocalTag } from './github_release_workflow.mjs';
import { waitForNotarizedBuild } from './xcode_cloud_release.mjs';

function usage() {
  console.log(`Usage: wait_for_xcode_cloud_notarized.mjs <tag> [--interval seconds] [--timeout seconds]

Poll Xcode Cloud until a successful notarized app artifact and xcarchive are available for the given tag.

The tag must exist in the local Git repository so its commit SHA can be used to match the Xcode Cloud build.

Environment:
  APP_STORE_CONNECT_ISSUER
  APP_STORE_CONNECT_KEY_ID
  APP_STORE_CONNECT_KEY_BASE64
`);
}

function parseArguments(argv) {
  const options = {
    intervalSeconds: 30,
    timeoutSeconds: 0,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];

    if (argument === '--help' || argument === '-h') {
      options.help = true;
      continue;
    }

    if (argument === '--interval') {
      options.intervalSeconds = Number(argv[index + 1]);
      index += 1;
      continue;
    }

    if (argument === '--timeout') {
      options.timeoutSeconds = Number(argv[index + 1]);
      index += 1;
      continue;
    }

    if (argument.startsWith('-')) {
      throw new Error(`Unknown option: ${argument}`);
    }

    if (options.tagName) {
      throw new Error(`Unexpected argument: ${argument}`);
    }

    options.tagName = argument;
  }

  return options;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    usage();
    return;
  }

  if (!options.tagName) {
    usage();
    process.exitCode = 64;
    return;
  }

  if (!Number.isFinite(options.intervalSeconds) || options.intervalSeconds <= 0) {
    throw new Error(`Invalid --interval value: ${options.intervalSeconds}`);
  }

  if (!Number.isFinite(options.timeoutSeconds) || options.timeoutSeconds < 0) {
    throw new Error(`Invalid --timeout value: ${options.timeoutSeconds}`);
  }

  if (!await hasLocalTag(options.tagName)) {
    throw new Error(`Local tag not found: ${options.tagName}`);
  }

  const tagSHA = await gitTagSHA(options.tagName);

  const result = await waitForNotarizedBuild({
    commitSha: tagSHA,
    intervalSeconds: options.intervalSeconds,
    ref: options.tagName,
    timeoutSeconds: options.timeoutSeconds,
  });

  console.log(JSON.stringify({
    buildRunId: result.buildRun.id,
    artifactFileName: result.artifact.attributes?.fileName ?? null,
    archiveArtifactFileName: result.archiveArtifact.attributes?.fileName ?? null,
    tagName: result.tagName,
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
