// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import fs from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

import { AppStoreConnectAPI, pemFromBase64 } from './app-store-connect-api.mjs';
import { findArchiveBuild, normalizeTagRef } from './notarized-build.mjs';

const {
  APP_STORE_CONNECT_ISSUER,
  APP_STORE_CONNECT_KEY_BASE64,
  APP_STORE_CONNECT_KEY_ID,
  INPUT_BUILD_RUN_ID,
  GITHUB_OUTPUT,
  GITHUB_REF,
  GITHUB_SHA,
  INPUT_PRODUCT_NAME,
  INPUT_WORKFLOW_NAME,
  JOB_TEMP,
} = process.env;

if (!APP_STORE_CONNECT_ISSUER) throw new Error('APP_STORE_CONNECT_ISSUER missing');
if (!APP_STORE_CONNECT_KEY_ID) throw new Error('APP_STORE_CONNECT_KEY_ID missing');
if (!APP_STORE_CONNECT_KEY_BASE64) throw new Error('APP_STORE_CONNECT_KEY_BASE64 missing');
if (!GITHUB_REF) throw new Error('GITHUB_REF missing');
if (!GITHUB_SHA) throw new Error('GITHUB_SHA missing');
if (!GITHUB_OUTPUT) throw new Error('GITHUB_OUTPUT missing');
if (!INPUT_PRODUCT_NAME) throw new Error('INPUT_PRODUCT_NAME missing');
if (!INPUT_WORKFLOW_NAME) throw new Error('INPUT_WORKFLOW_NAME missing');
if (!JOB_TEMP) throw new Error('JOB_TEMP missing');

function setOutput(name, value) {
  fs.appendFileSync(GITHUB_OUTPUT, `${name}=${value}\n`);
}

async function download(url, destination) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Download failed with ${response.status}: ${await response.text()}`);
  }

  if (!response.body) {
    throw new Error(`Download response did not include a body: ${url}`);
  }

  await pipeline(
    Readable.fromWeb(response.body),
    fs.createWriteStream(destination),
  );
}

async function main() {
  const outputDirectory = path.join(
    JOB_TEMP,
    'xcode-cloud-artifacts',
    INPUT_WORKFLOW_NAME.replaceAll(/[^0-9A-Za-z._-]/g, '-'),
  );
  const api = new AppStoreConnectAPI(
    APP_STORE_CONNECT_ISSUER,
    APP_STORE_CONNECT_KEY_ID,
    pemFromBase64(APP_STORE_CONNECT_KEY_BASE64),
  );
  const { gitRef, tagName } = normalizeTagRef(GITHUB_REF);
  const startedAt = Date.now();
  const timeoutMilliseconds = 150 * 60 * 1000;
  let result;
  let attempt = 0;
  while (!result) {
    attempt += 1;
    try {
      result = await findArchiveBuild({
        api,
        buildRunId: INPUT_BUILD_RUN_ID,
        productName: INPUT_PRODUCT_NAME,
        workflowName: INPUT_WORKFLOW_NAME,
        tagName,
        gitRef,
        commitSha: GITHUB_SHA,
        logger: console,
      });
    } catch (error) {
      const message = String(error?.message ?? error);
      const retryable = [
        'No Xcode Cloud build run matched tag',
        'No Archive action was found',
        'is not complete',
        'No downloadable Developer ID app artifact was found',
        'No downloadable xcarchive artifact was found',
      ].some((fragment) => message.includes(fragment)) ||
        /^GET \/v1\/.* failed with (?:408|429|500|502|503|504):/.test(message);
      if (!retryable || Date.now() - startedAt >= timeoutMilliseconds) {
        throw error;
      }

      console.error(`Xcode Cloud Archive artifacts are not ready (attempt ${attempt}): ${message}`);
      await new Promise((resolve) => setTimeout(resolve, 30_000));
    }
  }

  const { buildRun, artifact, archiveArtifact } = result;

  const attributes = artifact.attributes ?? {};
  const fileName = path.basename(attributes.fileName ?? 'xcode-cloud-developer-id-app.zip');
  const destination = path.join(outputDirectory, fileName);
  const archiveAttributes = archiveArtifact.attributes ?? {};
  const archiveFileName = path.basename(archiveAttributes.fileName ?? 'xcode-cloud-archive.xcarchive');
  const archiveDestination = path.join(outputDirectory, archiveFileName);

  fs.mkdirSync(outputDirectory, { recursive: true });
  await download(attributes.downloadUrl, destination);
  await download(archiveAttributes.downloadUrl, archiveDestination);

  setOutput('BUILD_ID', buildRun.id);
  setOutput('ARTIFACT_PATH', destination);
  setOutput('ARTIFACT_FILE_TYPE', attributes.fileType ?? '');
  setOutput('ARTIFACT_FILE_NAME', fileName);
  setOutput('ARCHIVE_ARTIFACT_PATH', archiveDestination);
  setOutput('ARCHIVE_ARTIFACT_FILE_TYPE', archiveAttributes.fileType ?? '');
  setOutput('ARCHIVE_ARTIFACT_FILE_NAME', archiveFileName);
  console.log(destination);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
