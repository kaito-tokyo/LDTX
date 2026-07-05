// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import fs from 'node:fs';
import path from 'node:path';

import { AppStoreConnectAPI } from './app-store-connect-api.mjs';

const artifactMatcher = /Notarized App|\.app\.zip$|\.zip$/i;
const outputDirectory = '.derivedData/Archives';
const tagPrefix = 'refs/tags/';

const {
  APP_STORE_CONNECT_ISSUER,
  APP_STORE_CONNECT_KEY,
  APP_STORE_CONNECT_KEY_ID,
  GITHUB_OUTPUT,
  GITHUB_REF,
  GITHUB_SHA,
  INPUT_PRODUCT_NAME,
  INPUT_WORKFLOW_NAME,
} = process.env;

if (!APP_STORE_CONNECT_ISSUER) throw new Error('APP_STORE_CONNECT_ISSUER missing');
if (!APP_STORE_CONNECT_KEY_ID) throw new Error('APP_STORE_CONNECT_KEY_ID missing');
if (!APP_STORE_CONNECT_KEY) throw new Error('APP_STORE_CONNECT_KEY missing');
if (!GITHUB_REF) throw new Error('GITHUB_REF missing');
if (!GITHUB_OUTPUT) throw new Error('GITHUB_OUTPUT missing');
if (!INPUT_PRODUCT_NAME) throw new Error('INPUT_PRODUCT_NAME missing');
if (!INPUT_WORKFLOW_NAME) throw new Error('INPUT_WORKFLOW_NAME missing');

if (!GITHUB_REF.startsWith(tagPrefix)) {
  throw new Error(`Release workflow must run on a tag ref; got ${GITHUB_REF}`);
}

const tagName = GITHUB_REF.slice(tagPrefix.length);
const api = new AppStoreConnectAPI(
  APP_STORE_CONNECT_ISSUER,
  APP_STORE_CONNECT_KEY_ID,
  APP_STORE_CONNECT_KEY,
);

function setOutput(name, value) {
  fs.appendFileSync(GITHUB_OUTPUT, `${name}=${value}\n`);
}

function nameOf(resource) {
  const attributes = resource.attributes ?? {};
  return attributes.name ?? attributes.displayName ?? attributes.productName ?? '';
}

function successful(attributes) {
  const completion = String(attributes.completionStatus ?? attributes.status ?? '').toUpperCase();
  return ['SUCCEEDED', 'SUCCESS', 'SUCCESSFUL', 'COMPLETED'].includes(completion);
}

function dateOf(resource) {
  const attributes = resource.attributes ?? {};
  for (const name of ['finishedDate', 'completedDate', 'startedDate', 'createdDate']) {
    const value = attributes[name];
    if (value) {
      const milliseconds = Date.parse(value);
      return Number.isNaN(milliseconds) ? 0 : milliseconds;
    }
  }

  return 0;
}

function candidateReferenceValues(buildRun) {
  const attributes = buildRun.attributes ?? {};
  const fieldNames = [
    'sourceBranchOrTag',
    'sourceBranch',
    'sourceTag',
    'gitReference',
    'gitRef',
    'ref',
    'branchName',
    'tagName',
  ];

  return fieldNames
    .map((fieldName) => [fieldName, attributes[fieldName]])
    .filter(([, value]) => value !== undefined && value !== null && value !== '');
}

function buildRunMatchesTag(buildRun) {
  const references = candidateReferenceValues(buildRun).map(([, value]) => String(value));
  const refMatches = references.some(
    (value) => value === tagName || value === `${tagPrefix}${tagName}` || value.endsWith(`/tags/${tagName}`),
  );
  if (refMatches) {
    return true;
  }

  const commitSha = buildRun.attributes?.commitSha;
  return Boolean(GITHUB_SHA && commitSha && commitSha === GITHUB_SHA);
}

function buildRunSummary(buildRun) {
  const attributes = buildRun.attributes ?? {};
  return {
    id: buildRun.id,
    completionStatus: attributes.completionStatus,
    status: attributes.status,
    finishedDate: attributes.finishedDate,
    completedDate: attributes.completedDate,
    startedDate: attributes.startedDate,
    createdDate: attributes.createdDate,
    commitSha: attributes.commitSha,
    references: Object.fromEntries(candidateReferenceValues(buildRun)),
  };
}

function actionSummary(action) {
  const attributes = action.attributes ?? {};
  return {
    id: action.id,
    name: attributes.name,
    displayName: attributes.displayName,
    actionType: attributes.actionType,
    completionStatus: attributes.completionStatus,
    status: attributes.status,
  };
}

function artifactSummary(artifact) {
  const attributes = artifact.attributes ?? {};
  return {
    id: artifact.id,
    fileName: attributes.fileName,
    fileType: attributes.fileType,
    name: attributes.name,
    displayName: attributes.displayName,
    hasDownloadUrl: Boolean(attributes.downloadUrl),
  };
}

function artifactSearchText(artifact) {
  const attributes = artifact.attributes ?? {};
  return [
    attributes.fileName,
    attributes.fileType,
    attributes.name,
    attributes.displayName,
  ]
    .filter(Boolean)
    .join(' ');
}

function artifactRank(artifact) {
  const text = artifactSearchText(artifact);
  if (/Notarized App/i.test(text)) return 0;
  if (/\.app\.zip$/i.test(text)) return 1;
  if (/\.zip$/i.test(text)) return 2;

  return 3;
}

function notarizeAction(action) {
  const attributes = action.attributes ?? {};
  const searchText = [
    attributes.name,
    attributes.displayName,
    attributes.actionType,
    attributes.title,
  ]
    .filter(Boolean)
    .join(' ');

  return successful(attributes) && /Notarize/i.test(searchText);
}

async function download(url, destination) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Download failed with ${response.status}: ${await response.text()}`);
  }

  fs.writeFileSync(destination, Buffer.from(await response.arrayBuffer()));
}

async function main() {
  const product = (await api.products()).find((candidate) => nameOf(candidate) === INPUT_PRODUCT_NAME);
  if (!product) {
    throw new Error(`Xcode Cloud product ${INPUT_PRODUCT_NAME} was not found.`);
  }

  const workflow = (await api.productWorkflows(product.id)).find(
    (candidate) => nameOf(candidate) === INPUT_WORKFLOW_NAME,
  );
  if (!workflow) {
    throw new Error(`Xcode Cloud workflow ${INPUT_WORKFLOW_NAME} was not found for product ${INPUT_PRODUCT_NAME}.`);
  }

  const buildRuns = await api.workflowBuildRuns(workflow.id);
  console.error('Xcode Cloud build run candidates:');
  console.error(JSON.stringify(buildRuns.map(buildRunSummary), null, 2));

  const buildRun = buildRuns
    .filter((candidate) => successful(candidate.attributes ?? {}) && buildRunMatchesTag(candidate))
    .sort((left, right) => dateOf(right) - dateOf(left))[0];
  if (!buildRun) {
    throw new Error(`No successful Xcode Cloud build run matched tag ${tagName}.`);
  }

  const actions = await api.buildActions(buildRun.id);
  console.error('Xcode Cloud build action candidates:');
  console.error(JSON.stringify(actions.map(actionSummary), null, 2));

  const action = actions.find(notarizeAction);
  if (!action) {
    throw new Error(`No successful Notarize action was found for Xcode Cloud build run ${buildRun.id}.`);
  }

  const artifacts = await api.actionArtifacts(action.id);
  console.error('Xcode Cloud artifact candidates:');
  console.error(JSON.stringify(artifacts.map(artifactSummary), null, 2));

  const artifact = artifacts
    .filter((candidate) => {
      const attributes = candidate.attributes ?? {};
      return attributes.downloadUrl && artifactMatcher.test(artifactSearchText(candidate));
    })
    .sort((left, right) => artifactRank(left) - artifactRank(right))[0];
  if (!artifact) {
    throw new Error(`No downloadable notarized app artifact was found for Xcode Cloud build action ${action.id}.`);
  }

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
