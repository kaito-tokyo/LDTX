// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import fs from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

import { AppStoreConnectAPI, pemFromBase64 } from './app-store-connect-api.mjs';
import { findNotarizedBuild, normalizeTagRef } from './notarized-build.mjs';

const outputDirectory = '.derivedData/Archives';

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
} = process.env;

if (!APP_STORE_CONNECT_ISSUER) throw new Error('APP_STORE_CONNECT_ISSUER missing');
if (!APP_STORE_CONNECT_KEY_ID) throw new Error('APP_STORE_CONNECT_KEY_ID missing');
if (!APP_STORE_CONNECT_KEY_BASE64) throw new Error('APP_STORE_CONNECT_KEY_BASE64 missing');
if (!GITHUB_REF) throw new Error('GITHUB_REF missing');
if (!GITHUB_OUTPUT) throw new Error('GITHUB_OUTPUT missing');
if (!INPUT_PRODUCT_NAME) throw new Error('INPUT_PRODUCT_NAME missing');
if (!INPUT_WORKFLOW_NAME) throw new Error('INPUT_WORKFLOW_NAME missing');

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
  const api = new AppStoreConnectAPI(
    APP_STORE_CONNECT_ISSUER,
    APP_STORE_CONNECT_KEY_ID,
    pemFromBase64(APP_STORE_CONNECT_KEY_BASE64),
  );
  const { gitRef, tagName } = normalizeTagRef(GITHUB_REF);
  const { buildRun, artifact, archiveArtifact } = await findNotarizedBuild({
    api,
    buildRunId: INPUT_BUILD_RUN_ID,
    productName: INPUT_PRODUCT_NAME,
    workflowName: INPUT_WORKFLOW_NAME,
    tagName,
    gitRef,
    commitSha: GITHUB_SHA,
    logger: console,
  });

  const attributes = artifact.attributes ?? {};
  const fileName = path.basename(attributes.fileName ?? 'xcode-cloud-notarized-app.zip');
  const destination = path.join(outputDirectory, fileName);
  const archiveAttributes = archiveArtifact.attributes ?? {};
  const archiveFileName = path.basename(archiveAttributes.fileName ?? 'xcode-cloud-archive.xcarchive');
  const archiveDestination = path.join(outputDirectory, archiveFileName);

  fs.mkdirSync(outputDirectory, { recursive: true });
  await download(attributes.downloadUrl, destination);
  await download(archiveAttributes.downloadUrl, archiveDestination);

  setOutput('build_id', buildRun.id);
  setOutput('artifact_path', destination);
  setOutput('artifact_file_type', attributes.fileType ?? '');
  setOutput('artifact_file_name', fileName);
  setOutput('archive_artifact_path', archiveDestination);
  setOutput('archive_artifact_file_type', archiveAttributes.fileType ?? '');
  setOutput('archive_artifact_file_name', archiveFileName);
  console.log(destination);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
