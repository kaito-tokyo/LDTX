#!/usr/bin/env node

// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import fs from 'node:fs';

import {
  dispatchReleaseWorkflow,
  gitTagSHA,
  hasLocalTag,
  waitForDispatchedWorkflowRun,
  watchWorkflowRun,
} from './github_release_workflow.mjs';
import { releaseWatchTimestamp, waitForNotarizedBuild } from './xcode_cloud_release.mjs';

function usage() {
  console.log(`Usage: run_release_after_tag.mjs [--interval seconds] [--watch-interval seconds] <tag>

Wait for Xcode Cloud's notarized artifact for <tag>, dispatch release.yml for that tag,
and wait for the GitHub Actions run to finish.

Examples:
  node ./ci_scripts/run_release_after_tag.mjs v0.1.4

Environment:
  APP_STORE_CONNECT_ISSUER
  APP_STORE_CONNECT_KEY_ID
  APP_STORE_CONNECT_KEY_BASE64
  GH_TOKEN (or an authenticated gh session)
  STATUS_PATH (optional status file path)
`);
}

function parseArguments(argv) {
  const options = {
    intervalSeconds: 30,
    watchIntervalSeconds: 10,
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

    if (argument === '--watch-interval') {
      options.watchIntervalSeconds = Number(argv[index + 1]);
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

function writeStatus(value) {
  if (process.env.STATUS_PATH) {
    fs.writeFileSync(process.env.STATUS_PATH, `${value}\n`);
  }
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

  if (!/^(v[0-9A-Za-z.+-]+)$/.test(options.tagName)) {
    throw new Error(`Tag must start with v and contain only SemVer characters: ${options.tagName}`);
  }

  if (!Number.isFinite(options.intervalSeconds) || options.intervalSeconds <= 0) {
    throw new Error(`Invalid --interval value: ${options.intervalSeconds}`);
  }

  if (!Number.isFinite(options.watchIntervalSeconds) || options.watchIntervalSeconds <= 0) {
    throw new Error(`Invalid --watch-interval value: ${options.watchIntervalSeconds}`);
  }

  if (!await hasLocalTag(options.tagName)) {
    throw new Error(`Local tag not found: ${options.tagName}`);
  }

  let currentStatus = 'starting';
  try {
    currentStatus = 'waiting-xcode-cloud';
    writeStatus(currentStatus);
    console.error(`[${releaseWatchTimestamp()}] Waiting for Xcode Cloud notarized artifact for ${options.tagName}`);
    await waitForNotarizedBuild({
      intervalSeconds: options.intervalSeconds,
      ref: options.tagName,
    });

    const tagSHA = await gitTagSHA(options.tagName);
    const dispatchedAfter = new Date().toISOString();

    currentStatus = 'dispatching-release-workflow';
    writeStatus(currentStatus);
    await dispatchReleaseWorkflow({ tagName: options.tagName });

    currentStatus = 'waiting-github-actions-run';
    writeStatus(currentStatus);
    const run = await waitForDispatchedWorkflowRun({
      dispatchedAfter,
      intervalSeconds: options.watchIntervalSeconds,
      tagName: options.tagName,
      tagSHA,
    });

    currentStatus = 'watching-github-actions-run';
    writeStatus(currentStatus);
    console.error(
      `[${releaseWatchTimestamp()}] Watching GitHub Actions run ${run.databaseId}${run.url ? ` (${run.url})` : ''}`,
    );
    await watchWorkflowRun({
      intervalSeconds: options.watchIntervalSeconds,
      runId: run.databaseId,
    });

    currentStatus = 'completed';
    writeStatus(currentStatus);
    console.error(`[${releaseWatchTimestamp()}] Release workflow completed successfully for ${options.tagName}`);
  } catch (error) {
    writeStatus(`failed:${currentStatus}`);
    throw error;
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
