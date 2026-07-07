#!/usr/bin/env node

// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import { AppStoreConnectAPI, pemFromBase64 } from '../.github/actions/download-xcode-cloud-notarized/app-store-connect-api.mjs';
import { findNotarizedBuild, normalizeTagRef } from '../.github/actions/download-xcode-cloud-notarized/notarized-build.mjs';

function usage() {
  console.log(`Usage: wait_for_xcode_cloud_notarized.mjs <tag> [--interval seconds] [--timeout seconds]

Poll Xcode Cloud until a successful notarized app artifact is available for the given tag.

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

function now() {
  return new Date().toISOString();
}

function sleep(milliseconds) {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });
}

function retryable(error) {
  const message = String(error?.message ?? error);
  return [
    'No successful Xcode Cloud build run matched tag',
    'No successful Notarize action was found',
    'No downloadable notarized app artifact was found',
    'GET /v1/',
    'failed with 500',
    'failed with 502',
    'failed with 503',
    'failed with 504',
  ].some((fragment) => message.includes(fragment));
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

  const {
    APP_STORE_CONNECT_ISSUER,
    APP_STORE_CONNECT_KEY_BASE64,
    APP_STORE_CONNECT_KEY_ID,
    GITHUB_SHA,
  } = process.env;

  if (!APP_STORE_CONNECT_ISSUER) throw new Error('APP_STORE_CONNECT_ISSUER missing');
  if (!APP_STORE_CONNECT_KEY_ID) throw new Error('APP_STORE_CONNECT_KEY_ID missing');
  if (!APP_STORE_CONNECT_KEY_BASE64) throw new Error('APP_STORE_CONNECT_KEY_BASE64 missing');

  const api = new AppStoreConnectAPI(
    APP_STORE_CONNECT_ISSUER,
    APP_STORE_CONNECT_KEY_ID,
    pemFromBase64(APP_STORE_CONNECT_KEY_BASE64),
  );
  const { gitRef, tagName } = normalizeTagRef(options.tagName);

  const startedAt = Date.now();
  const timeoutMilliseconds = options.timeoutSeconds * 1000;
  let attempt = 0;

  while (true) {
    attempt += 1;
    console.error(`[${now()}] Checking Xcode Cloud for ${tagName} (attempt ${attempt})`);

    try {
      const result = await findNotarizedBuild({
        api,
        productName: 'LDTX',
        workflowName: 'On push tag',
        tagName,
        gitRef,
        commitSha: GITHUB_SHA,
        logger: console,
      });

      console.log(JSON.stringify({
        buildRunId: result.buildRun.id,
        artifactFileName: result.artifact.attributes?.fileName ?? null,
        tagName,
      }, null, 2));
      return;
    } catch (error) {
      if (!retryable(error)) {
        throw error;
      }

      if (timeoutMilliseconds > 0 && Date.now() - startedAt >= timeoutMilliseconds) {
        throw new Error(
          `Timed out after ${options.timeoutSeconds} seconds waiting for Xcode Cloud notarized build for ${tagName}: ${String(error?.message ?? error)}`,
        );
      }

      console.error(`[${now()}] Not ready yet: ${String(error?.message ?? error)}`);
      await sleep(options.intervalSeconds * 1000);
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
