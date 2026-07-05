// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import fs from 'node:fs';
import path from 'node:path';

import { AppStoreConnectAPI } from './app-store-connect-api.mjs';

const notarizedArchiveFileType = 'STAPLED_NOTARIZED_ARCHIVE';
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

function candidateSourceBranchOrTagValues(sourceBranchOrTag) {
  if (!sourceBranchOrTag) {
    return [];
  }

  const attributes = sourceBranchOrTag.attributes ?? {};
  const fieldNames = [
    'name',
    'displayName',
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
    .map((fieldName) => [`sourceBranchOrTag.${fieldName}`, attributes[fieldName]])
    .filter(([, value]) => value !== undefined && value !== null && value !== '');
}

function candidateRelationshipValues(buildRun) {
  const data = buildRun.relationships?.sourceBranchOrTag?.data;
  if (!data || Array.isArray(data)) {
    return [];
  }

  return data.id ? [['relationships.sourceBranchOrTag.data.id', data.id]] : [];
}

function candidateCommitShaValues(buildRun) {
  const attributes = buildRun.attributes ?? {};
  const sourceCommit = attributes.sourceCommit ?? {};

  return [
    ['commitSha', attributes.commitSha],
    ['sourceCommit.commitSha', sourceCommit.commitSha],
  ].filter(([, value]) => value !== undefined && value !== null && value !== '');
}

function buildRunMatchesTag(buildRunContext) {
  const { buildRun, sourceBranchOrTag } = buildRunContext;
  const references = [
    ...candidateReferenceValues(buildRun),
    ...candidateSourceBranchOrTagValues(sourceBranchOrTag),
    ...candidateRelationshipValues(buildRun),
  ].map(([, value]) => String(value));
  const refMatches = references.some(
    (value) => value === tagName || value === `${tagPrefix}${tagName}` || value.endsWith(`/tags/${tagName}`),
  );
  if (refMatches) {
    return true;
  }

  const commitShas = candidateCommitShaValues(buildRun).map(([, value]) => String(value));
  return Boolean(GITHUB_SHA && commitShas.some((commitSha) => commitSha === GITHUB_SHA));
}

function buildRunSummary(buildRunContext) {
  const { buildRun, sourceBranchOrTag, sourceBranchOrTagError } = buildRunContext;
  const attributes = buildRun.attributes ?? {};
  return {
    id: buildRun.id,
    completionStatus: attributes.completionStatus,
    status: attributes.status,
    finishedDate: attributes.finishedDate,
    completedDate: attributes.completedDate,
    startedDate: attributes.startedDate,
    createdDate: attributes.createdDate,
    commitSha: attributes.commitSha ?? attributes.sourceCommit?.commitSha,
    commitShas: Object.fromEntries(candidateCommitShaValues(buildRun)),
    references: Object.fromEntries([
      ...candidateReferenceValues(buildRun),
      ...candidateSourceBranchOrTagValues(sourceBranchOrTag),
      ...candidateRelationshipValues(buildRun),
    ]),
    sourceBranchOrTag: sourceBranchOrTag ? {
      id: sourceBranchOrTag.id,
      type: sourceBranchOrTag.type,
      name: nameOf(sourceBranchOrTag),
    } : undefined,
    sourceBranchOrTagError,
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

function artifactFileName(artifact) {
  return String(artifact.attributes?.fileName ?? '');
}

function artifactFileType(artifact) {
  return String(artifact.attributes?.fileType ?? '');
}

function downloadableNotarizedAppArtifact(artifact) {
  const attributes = artifact.attributes ?? {};
  const fileName = artifactFileName(artifact);
  const fileType = artifactFileType(artifact);

  return Boolean(attributes.downloadUrl) && (
    fileType === notarizedArchiveFileType ||
    /\.app\.zip$/i.test(fileName) ||
    /Notarized App/i.test(artifactSearchText(artifact))
  );
}

function artifactRank(artifact) {
  const fileName = artifactFileName(artifact);
  const fileType = artifactFileType(artifact);
  const text = artifactSearchText(artifact);
  if (fileType === notarizedArchiveFileType && /\.app\.zip$/i.test(fileName)) return 0;
  if (fileType === notarizedArchiveFileType) return 1;
  if (/Notarized App/i.test(text)) return 2;
  if (/\.app\.zip$/i.test(fileName)) return 3;

  return 4;
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

async function buildRunContext(buildRun) {
  try {
    return {
      buildRun,
      sourceBranchOrTag: await api.relatedResource(buildRun, 'sourceBranchOrTag'),
    };
  } catch (error) {
    return {
      buildRun,
      sourceBranchOrTagError: String(error?.message ?? error),
    };
  }
}

async function buildRunContextForMatching(buildRun) {
  const context = { buildRun };
  if (buildRunMatchesTag(context)) {
    return context;
  }

  return buildRunContext(buildRun);
}

async function findMatchingBuildRunFromPages(workflowId, { sort, stopAfterFirstMatch }) {
  const matches = [];
  let page = 0;

  for await (const buildRuns of api.workflowBuildRunPages(workflowId, { sort })) {
    page += 1;
    const buildRunContexts = await Promise.all(buildRuns.map(buildRunContextForMatching));
    console.error(`Xcode Cloud build run candidates page ${page}:`);
    console.error(JSON.stringify(buildRunContexts.map(buildRunSummary), null, 2));

    const pageMatches = buildRunContexts
      .filter((candidate) => successful(candidate.buildRun.attributes ?? {}) && buildRunMatchesTag(candidate));
    matches.push(...pageMatches);

    if (stopAfterFirstMatch && pageMatches.length > 0) {
      break;
    }
  }

  return matches
    .sort((left, right) => dateOf(right.buildRun) - dateOf(left.buildRun))[0]?.buildRun;
}

async function findMatchingBuildRun(workflowId) {
  try {
    return await findMatchingBuildRunFromPages(workflowId, {
      sort: '-createdDate',
      stopAfterFirstMatch: true,
    });
  } catch (error) {
    if (!String(error).includes('failed with 400')) {
      throw error;
    }

    console.warn(`Could not list Xcode Cloud build runs newest-first; retrying without sort: ${error}`);
    return findMatchingBuildRunFromPages(workflowId, {
      stopAfterFirstMatch: false,
    });
  }
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

  const buildRun = await findMatchingBuildRun(workflow.id);
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
    .filter(downloadableNotarizedAppArtifact)
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
