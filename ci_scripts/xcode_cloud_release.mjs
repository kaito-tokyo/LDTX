// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import { AppStoreConnectAPI, pemFromBase64 } from '../.github/actions/download-xcode-cloud-notarized/app-store-connect-api.mjs';
import { findNotarizedBuild, normalizeTagRef } from '../.github/actions/download-xcode-cloud-notarized/notarized-build.mjs';

/**
 * Returns an ISO-8601 timestamp for release watcher logs.
 */
export function releaseWatchTimestamp() {
  return new Date().toISOString();
}

/**
 * Waits for the given duration.
 *
 * @param {number} milliseconds
 * @returns {Promise<void>}
 */
export function sleep(milliseconds) {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });
}

/**
 * Builds an App Store Connect API client from process-like environment variables.
 *
 * Required variables:
 * - APP_STORE_CONNECT_ISSUER
 * - APP_STORE_CONNECT_KEY_ID
 * - APP_STORE_CONNECT_KEY_BASE64
 *
 * @param {NodeJS.ProcessEnv} [env=process.env]
 * @returns {AppStoreConnectAPI}
 */
export function appStoreConnectAPIFromEnv(env = process.env) {
  const {
    APP_STORE_CONNECT_ISSUER,
    APP_STORE_CONNECT_KEY_BASE64,
    APP_STORE_CONNECT_KEY_ID,
  } = env;

  if (!APP_STORE_CONNECT_ISSUER) throw new Error('APP_STORE_CONNECT_ISSUER missing');
  if (!APP_STORE_CONNECT_KEY_ID) throw new Error('APP_STORE_CONNECT_KEY_ID missing');
  if (!APP_STORE_CONNECT_KEY_BASE64) throw new Error('APP_STORE_CONNECT_KEY_BASE64 missing');

  return new AppStoreConnectAPI(
    APP_STORE_CONNECT_ISSUER,
    APP_STORE_CONNECT_KEY_ID,
    pemFromBase64(APP_STORE_CONNECT_KEY_BASE64),
  );
}

/**
 * Returns whether a notarized-build lookup error is worth retrying.
 *
 * This treats both "not ready yet" conditions and transient 5xx API errors as
 * retryable so operators can keep polling while Xcode Cloud is still working.
 *
 * @param {unknown} error
 * @returns {boolean}
 */
export function isRetryableNotarizedBuildError(error) {
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

/**
 * Polls Xcode Cloud until a notarized app artifact is available for the given
 * tag or fully-qualified git ref.
 *
 * @param {object} options
 * @param {AppStoreConnectAPI} [options.api]
 * @param {string} [options.commitSha]
 * @param {NodeJS.ProcessEnv} [options.env=process.env]
 * @param {number} [options.intervalSeconds=30]
 * @param {Console} [options.logger=console]
 * @param {string} options.ref
 * @param {number} [options.timeoutSeconds=0]
 * @param {string} [options.productName='LDTX']
 * @param {string} [options.workflowName='On push tag']
 * @returns {Promise<{
 *   artifact: any,
 *   attempt: number,
 *   buildRun: any,
 *   gitRef: string,
 *   tagName: string,
 * }>}
 */
export async function waitForNotarizedBuild({
  api,
  commitSha,
  env = process.env,
  intervalSeconds = 30,
  logger = console,
  ref,
  timeoutSeconds = 0,
  productName = 'LDTX',
  workflowName = 'On push tag',
}) {
  if (!Number.isFinite(intervalSeconds) || intervalSeconds <= 0) {
    throw new Error(`Invalid intervalSeconds value: ${intervalSeconds}`);
  }

  if (!Number.isFinite(timeoutSeconds) || timeoutSeconds < 0) {
    throw new Error(`Invalid timeoutSeconds value: ${timeoutSeconds}`);
  }

  const resolvedAPI = api ?? appStoreConnectAPIFromEnv(env);
  const { gitRef, tagName } = normalizeTagRef(ref);
  const startedAt = Date.now();
  const timeoutMilliseconds = timeoutSeconds * 1000;
  let attempt = 0;

  while (true) {
    attempt += 1;
    logger.error(`[${releaseWatchTimestamp()}] Checking Xcode Cloud for ${tagName} (attempt ${attempt})`);

    try {
      const result = await findNotarizedBuild({
        api: resolvedAPI,
        productName,
        workflowName,
        tagName,
        gitRef,
        commitSha: commitSha ?? env.GITHUB_SHA,
        logger,
      });
      return {
        ...result,
        attempt,
        gitRef,
        tagName,
      };
    } catch (error) {
      if (!isRetryableNotarizedBuildError(error)) {
        throw error;
      }

      if (timeoutMilliseconds > 0 && Date.now() - startedAt >= timeoutMilliseconds) {
        throw new Error(
          `Timed out after ${timeoutSeconds} seconds waiting for Xcode Cloud notarized build for ${tagName}: ${String(error?.message ?? error)}`,
        );
      }

      logger.error(`[${releaseWatchTimestamp()}] Not ready yet: ${String(error?.message ?? error)}`);
      await sleep(intervalSeconds * 1000);
    }
  }
}
