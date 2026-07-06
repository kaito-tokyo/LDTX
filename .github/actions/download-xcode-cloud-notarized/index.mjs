// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import fs from 'node:fs';
import path from 'node:path';

import { AppStoreConnectAPI, pemFromBase64 } from './app-store-connect-api.mjs';
import { findNotarizedBuild, normalizeTagRef } from './notarized-build.mjs';

const outputDirectory = '.derivedData/Archives';

const {
  APP_STORE_CONNECT_ISSUER,
  APP_STORE_CONNECT_KEY_BASE64,
  APP_STORE_CONNECT_KEY_ID,
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

  fs.writeFileSync(destination, Buffer.from(await response.arrayBuffer()));
}

async function main() {
  const api = new AppStoreConnectAPI(
    APP_STORE_CONNECT_ISSUER,
    APP_STORE_CONNECT_KEY_ID,
    pemFromBase64(APP_STORE_CONNECT_KEY_BASE64),
  );
  const { gitRef, tagName } = normalizeTagRef(GITHUB_REF);
  const { buildRun, artifact } = await findNotarizedBuild({
    api,
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

  fs.mkdirSync(outputDirectory, { recursive: true });
  await download(attributes.downloadUrl, destination);

  setOutput('build_id', buildRun.id);
  setOutput('artifact_path', destination);
  setOutput('artifact_file_type', attributes.fileType ?? '');
  setOutput('artifact_file_name', fileName);
  console.log(destination);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
