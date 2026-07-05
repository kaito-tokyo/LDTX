// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const apiBase = 'https://api.appstoreconnect.apple.com';
const waitSeconds = 3600;
const pollSeconds = 30;

function input(name, fallback = undefined) {
  const rawName = `INPUT_${name.toUpperCase()}`;
  const normalizedName = rawName.replace(/-/g, '_');
  const value = process.env[rawName] ?? process.env[normalizedName] ?? fallback;
  if (value === undefined || value === '') {
    throw new Error(`Missing required input: ${name}`);
  }
  return value;
}

function env(name) {
  const value = process.env[name];
  if (value === undefined || value === '') {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

function appStoreConnectJwt() {
  const issuedAt = Math.floor(Date.now() / 1000) - 60;
  const header = {
    alg: 'ES256',
    kid: env('APP_STORE_CONNECT_KEY_ID'),
    typ: 'JWT',
  };
  const payload = {
    iss: env('APP_STORE_CONNECT_ISSUER'),
    iat: issuedAt,
    exp: issuedAt + 19 * 60,
    aud: 'appstoreconnect-v1',
  };
  const signingInput = [base64url(JSON.stringify(header)), base64url(JSON.stringify(payload))].join('.');
  const privateKey = env('APP_STORE_CONNECT_KEY');
  const signature = crypto.sign('sha256', Buffer.from(signingInput), {
    key: privateKey,
    dsaEncoding: 'ieee-p1363',
  });

  return `${signingInput}.${signature.toString('base64url')}`;
}

async function appStoreConnectGet(pathname) {
  const response = await fetch(`${apiBase}${pathname}`, {
    headers: {
      Authorization: `Bearer ${appStoreConnectJwt()}`,
    },
  });
  if (!response.ok) {
    throw new Error(`GET ${pathname} failed with ${response.status}: ${await response.text()}`);
  }
  return response.json();
}

async function buildActions(buildId) {
  const response = await appStoreConnectGet(`/v1/ciBuildRuns/${buildId}/actions?limit=200`);
  return response.data;
}

async function actionArtifacts(actionId) {
  const response = await appStoreConnectGet(`/v1/ciBuildActions/${actionId}/artifacts?limit=200`);
  return response.data;
}

async function archiveActions(buildId) {
  return (await buildActions(buildId)).filter((action) => {
    const attributes = action.attributes ?? {};
    return attributes.actionType === 'ARCHIVE' && attributes.completionStatus === 'SUCCEEDED';
  });
}

async function matchingArtifact(buildId, preferredTypes) {
  for (const action of await archiveActions(buildId)) {
    for (const artifact of await actionArtifacts(action.id)) {
      const attributes = artifact.attributes ?? {};
      if (preferredTypes.includes(attributes.fileType) && attributes.downloadUrl) {
        return artifact;
      }
    }
  }
  return undefined;
}

function sleep(milliseconds) {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });
}

async function waitForArtifact(buildId, preferredTypes, waitSeconds, pollSeconds) {
  const deadline = Date.now() + waitSeconds * 1000;

  while (Date.now() <= deadline) {
    const artifact = await matchingArtifact(buildId, preferredTypes);
    if (artifact) {
      return artifact;
    }

    console.error(`Waiting for Xcode Cloud artifact ${preferredTypes.join(', ')} from build ${buildId}...`);
    await sleep(pollSeconds * 1000);
  }

  throw new Error(`Timed out waiting for Xcode Cloud artifact ${preferredTypes.join(', ')} from build ${buildId}`);
}

async function download(url, destination) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Download failed with ${response.status}: ${await response.text()}`);
  }

  const bytes = Buffer.from(await response.arrayBuffer());
  fs.writeFileSync(destination, bytes);
}

function setOutput(name, value) {
  fs.appendFileSync(env('GITHUB_OUTPUT'), `${name}=${value}\n`);
}

async function main() {
  const buildId = input('build-id');
  const preferredTypes = input('artifact-types', 'ARCHIVE_EXPORT')
    .split(',')
    .map((artifactType) => artifactType.trim())
    .filter((artifactType) => artifactType.length > 0);
  const outputDirectory = input('output-directory', '.derivedData/Archives');

  fs.mkdirSync(outputDirectory, { recursive: true });

  const artifact = await waitForArtifact(buildId, preferredTypes, waitSeconds, pollSeconds);
  const attributes = artifact.attributes;
  const fileName = attributes.fileName ?? 'xcode-cloud-artifact.zip';
  const destination = path.join(outputDirectory, fileName);

  await download(attributes.downloadUrl, destination);

  setOutput('artifact_path', destination);
  setOutput('artifact_file_type', attributes.fileType ?? '');
  setOutput('artifact_file_name', fileName);
  console.log(destination);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
