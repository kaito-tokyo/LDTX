// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

export const notarizedArchiveFileType = 'STAPLED_NOTARIZED_ARCHIVE';
export const tagPrefix = 'refs/tags/';

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

function buildRunMatchesTag(buildRunContext, { tagName, gitRef, commitSha }) {
  const { buildRun, sourceBranchOrTag } = buildRunContext;
  const references = [
    ...candidateReferenceValues(buildRun),
    ...candidateSourceBranchOrTagValues(sourceBranchOrTag),
    ...candidateRelationshipValues(buildRun),
  ].map(([, value]) => String(value));
  const refCandidates = [tagName, `${tagPrefix}${tagName}`, gitRef].filter(Boolean);
  const refMatches = references.some(
    (value) => refCandidates.includes(value) || value.endsWith(`/tags/${tagName}`),
  );
  if (refMatches) {
    return true;
  }

  const commitShas = candidateCommitShaValues(buildRun).map(([, value]) => String(value));
  return Boolean(commitSha && commitShas.some((candidate) => candidate === commitSha));
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

async function buildRunContext(api, buildRun) {
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

async function buildRunContextForMatching(api, buildRun, matcher) {
  const context = { buildRun };
  if (matcher(context)) {
    return context;
  }

  return buildRunContext(api, buildRun);
}

async function findMatchingBuildRunFromPages(api, workflowId, matcher, logger, { sort, stopAfterFirstMatch }) {
  const matches = [];
  let page = 0;

  for await (const buildRuns of api.workflowBuildRunPages(workflowId, { sort })) {
    page += 1;
    const buildRunContexts = await Promise.all(
      buildRuns.map((buildRun) => buildRunContextForMatching(api, buildRun, matcher)),
    );
    logger.error(`Xcode Cloud build run candidates page ${page}:`);
    logger.error(JSON.stringify(buildRunContexts.map(buildRunSummary), null, 2));

    const pageMatches = buildRunContexts.filter(
      (candidate) => successful(candidate.buildRun.attributes ?? {}) && matcher(candidate),
    );
    matches.push(...pageMatches);

    if (stopAfterFirstMatch && pageMatches.length > 0) {
      break;
    }
  }

  return matches.sort((left, right) => dateOf(right.buildRun) - dateOf(left.buildRun))[0]?.buildRun;
}

async function findMatchingBuildRun(api, workflowId, matcher, logger) {
  try {
    return await findMatchingBuildRunFromPages(api, workflowId, matcher, logger, {
      sort: '-createdDate',
      stopAfterFirstMatch: true,
    });
  } catch (error) {
    if (!String(error).includes('failed with 400')) {
      throw error;
    }

    logger.warn(`Could not list Xcode Cloud build runs newest-first; retrying without sort: ${error}`);
    return findMatchingBuildRunFromPages(api, workflowId, matcher, logger, {
      stopAfterFirstMatch: false,
    });
  }
}

export function normalizeTagRef(value) {
  if (!value) {
    throw new Error('tag or git ref is required');
  }

  if (value.startsWith(tagPrefix)) {
    return { gitRef: value, tagName: value.slice(tagPrefix.length) };
  }

  return { gitRef: `${tagPrefix}${value}`, tagName: value };
}

export async function findNotarizedBuild({
  api,
  productName,
  workflowName,
  tagName,
  gitRef,
  commitSha,
  logger = console,
}) {
  const product = (await api.products()).find((candidate) => nameOf(candidate) === productName);
  if (!product) {
    throw new Error(`Xcode Cloud product ${productName} was not found.`);
  }

  const workflow = (await api.productWorkflows(product.id)).find(
    (candidate) => nameOf(candidate) === workflowName,
  );
  if (!workflow) {
    throw new Error(`Xcode Cloud workflow ${workflowName} was not found for product ${productName}.`);
  }

  const matcher = (buildRunContext) => buildRunMatchesTag(buildRunContext, { tagName, gitRef, commitSha });
  const buildRun = await findMatchingBuildRun(api, workflow.id, matcher, logger);
  if (!buildRun) {
    throw new Error(`No successful Xcode Cloud build run matched tag ${tagName}.`);
  }

  const actions = await api.buildActions(buildRun.id);
  logger.error('Xcode Cloud build action candidates:');
  logger.error(JSON.stringify(actions.map(actionSummary), null, 2));

  const action = actions.find(notarizeAction);
  if (!action) {
    throw new Error(`No successful Notarize action was found for Xcode Cloud build run ${buildRun.id}.`);
  }

  const artifacts = await api.actionArtifacts(action.id);
  logger.error('Xcode Cloud artifact candidates:');
  logger.error(JSON.stringify(artifacts.map(artifactSummary), null, 2));

  const artifact = artifacts
    .filter(downloadableNotarizedAppArtifact)
    .sort((left, right) => artifactRank(left) - artifactRank(right))[0];
  if (!artifact) {
    throw new Error(`No downloadable notarized app artifact was found for Xcode Cloud build action ${action.id}.`);
  }

  return {
    product,
    workflow,
    buildRun,
    notarizeAction: action,
    artifact,
  };
}
