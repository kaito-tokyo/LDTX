// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

export const archiveExportFileType = 'ARCHIVE_EXPORT';
export const tagPrefix = 'refs/tags/';
export const xcarchiveFileNamePattern = /\.xcarchive(?:\.zip)?$/i;

function nameOf(resource) {
  const attributes = resource.attributes ?? {};
  return attributes.name ?? attributes.displayName ?? attributes.productName ?? '';
}

function failed(attributes) {
  const completion = String(attributes.completionStatus ?? attributes.status ?? '').toUpperCase();
  return ['CANCELED', 'CANCELLED', 'ERRORED', 'FAILED', 'FAILURE', 'SKIPPED'].includes(completion);
}

function succeeded(attributes) {
  const completion = String(attributes.completionStatus ?? attributes.status ?? '').toUpperCase();
  return ['COMPLETE', 'COMPLETED', 'SUCCESS', 'SUCCEEDED'].includes(completion);
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
  const commitShas = candidateCommitShaValues(buildRun).map(([, value]) => String(value));
  const commitMatches = Boolean(
    commitSha && commitShas.some((candidate) => candidate === commitSha),
  );
  return refMatches && commitMatches;
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

function actionSearchText(action) {
  const attributes = action.attributes ?? {};
  return [
    attributes.name,
    attributes.displayName,
    attributes.actionType,
    attributes.title,
  ]
    .filter(Boolean)
    .join(' ');
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

function downloadableDeveloperIdAppArtifact(artifact) {
  const attributes = artifact.attributes ?? {};
  const fileName = artifactFileName(artifact);
  const fileType = artifactFileType(artifact);

  return Boolean(attributes.downloadUrl) &&
    fileType === archiveExportFileType &&
    /developer-id.*\.zip$/i.test(fileName);
}

function developerIdArtifactRank(artifact) {
  const fileName = artifactFileName(artifact);
  if (/ developer-id\.zip$/i.test(fileName)) return 0;
  if (/developer-id.*\.zip$/i.test(fileName)) return 1;

  return 2;
}

function downloadableArchiveArtifact(artifact) {
  const attributes = artifact.attributes ?? {};
  const fileName = artifactFileName(artifact);
  const text = artifactSearchText(artifact);

  return Boolean(attributes.downloadUrl) && (
    xcarchiveFileNamePattern.test(fileName) ||
    /\bxcarchive\b/i.test(text) ||
    /Archive for/i.test(text)
  );
}

function archiveArtifactRank({ action, artifact }) {
  const fileName = artifactFileName(artifact);
  const text = artifactSearchText(artifact);
  const actionText = actionSearchText(action);
  if (xcarchiveFileNamePattern.test(fileName) && /Archive/i.test(actionText)) return 0;
  if (xcarchiveFileNamePattern.test(fileName)) return 1;
  if (/\bxcarchive\b/i.test(text) && /Archive/i.test(actionText)) return 2;
  if (/\bxcarchive\b/i.test(text)) return 3;
  if (/Archive for/i.test(text) && /Archive/i.test(actionText)) return 4;
  if (/Archive for/i.test(text)) return 5;

  return 6;
}

function archiveAction(action) {
  const text = actionSearchText(action);
  return /Archive/i.test(text) && !/Notarize/i.test(text);
}

function artifactContextSummary({ action, artifact }) {
  return {
    action: actionSummary(action),
    artifact: artifactSummary(artifact),
  };
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

async function* matchingBuildRunsFromPages(api, workflowId, matcher, logger, { sort } = {}) {
  let page = 0;

  for await (const buildRuns of api.workflowBuildRunPages(workflowId, { sort })) {
    page += 1;
    for (const buildRun of buildRuns) {
      const buildRunContext = await buildRunContextForMatching(api, buildRun, matcher);
      logger.error(`Xcode Cloud build run candidate page ${page}:`);
      logger.error(JSON.stringify(buildRunSummary(buildRunContext), null, 2));
      if (matcher(buildRunContext)) {
        yield buildRun;
      }
    }
  }
}

async function* matchingBuildRuns(api, workflowId, matcher, logger) {
  let yieldedBuildRun = false;
  try {
    for await (const buildRun of matchingBuildRunsFromPages(
      api,
      workflowId,
      matcher,
      logger,
      { sort: '-createdDate' },
    )) {
      yieldedBuildRun = true;
      yield buildRun;
    }
    return;
  } catch (error) {
    if (yieldedBuildRun || !String(error).includes('failed with 400')) {
      throw error;
    }

    logger.warn(`Could not list Xcode Cloud build runs newest-first; retrying without sort: ${error}`);
  }

  const matches = [];
  for await (const buildRun of matchingBuildRunsFromPages(api, workflowId, matcher, logger)) {
    matches.push(buildRun);
  }
  matches.sort((left, right) => dateOf(right) - dateOf(left));
  for (const buildRun of matches) {
    yield buildRun;
  }
}

async function findBuildRunInWorkflowById(api, workflowId, buildRunId) {
  for await (const buildRuns of api.workflowBuildRunPages(workflowId)) {
    const buildRun = buildRuns.find((candidate) => candidate.id === buildRunId);
    if (buildRun) {
      return buildRun;
    }
  }

  return undefined;
}

async function findBuildRunById(api, workflowId, buildRunId, matcher) {
  const buildRun = await findBuildRunInWorkflowById(api, workflowId, buildRunId);
  if (!buildRun) {
    throw new Error(`Xcode Cloud build run ${buildRunId} does not belong to the requested workflow.`);
  }

  const context = await buildRunContext(api, buildRun);
  if (!matcher(context)) {
    throw new Error(`Xcode Cloud build run ${buildRunId} does not match the requested tag or commit.`);
  }

  return buildRun;
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

export async function findArchiveBuild({
  api,
  buildRunId,
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
  let buildRuns;

  if (buildRunId) {
    buildRuns = [await findBuildRunById(api, workflow.id, buildRunId, matcher)];
  } else {
    buildRuns = matchingBuildRuns(api, workflow.id, matcher, logger);
  }

  let selected;
  let terminalBuildError;
  for await (const buildRun of buildRuns) {
    const actions = await api.buildActions(buildRun.id);
    logger.error(`Xcode Cloud build action candidates for build run ${buildRun.id}:`);
    logger.error(JSON.stringify(actions.map(actionSummary), null, 2));

    const action = actions.find(archiveAction);
    if (!action) {
      if (!buildRunId && failed(buildRun.attributes ?? {})) {
        terminalBuildError = new Error(
          `Xcode Cloud build run ${buildRun.id} failed before an Archive action was created.`,
        );
        logger.warn(`Skipping ${terminalBuildError.message}`);
        continue;
      }
      throw new Error(`No Archive action was found for Xcode Cloud build run ${buildRun.id}.`);
    }

    const artifacts = await api.actionArtifacts(action.id);
    logger.error('Xcode Cloud artifact candidates:');
    logger.error(JSON.stringify(
      [{
        action: actionSummary(action),
        artifacts: artifacts.map(artifactSummary),
      }],
      null,
      2,
    ));

    const artifact = artifacts
      .filter(downloadableDeveloperIdAppArtifact)
      .sort((left, right) => developerIdArtifactRank(left) - developerIdArtifactRank(right))[0];
    const archiveArtifact = artifacts
      .map((artifactCandidate) => ({ action, artifact: artifactCandidate }))
      .filter(({ artifact: artifactCandidate }) => downloadableArchiveArtifact(artifactCandidate))
      .sort((left, right) => archiveArtifactRank(left) - archiveArtifactRank(right))[0]?.artifact;

    if (artifact && archiveArtifact) {
      selected = { buildRun, action, artifacts, artifact, archiveArtifact };
      break;
    }

    if (failed(action.attributes ?? {})) {
      terminalBuildError = new Error(
        `Xcode Cloud Archive action ${action.id} ended without the required release artifacts.`,
      );
      if (buildRunId) {
        throw terminalBuildError;
      }
      logger.warn(
        `Skipping Xcode Cloud build run ${buildRun.id} because Archive action ${action.id} failed.`,
      );
      continue;
    }

    if (succeeded(action.attributes ?? {})) {
      const missingArtifacts = [
        !artifact && 'Developer ID app export',
        !archiveArtifact && 'xcarchive',
      ].filter(Boolean).join(' and ');
      throw new Error(
        `Xcode Cloud Archive action ${action.id} completed without the required ${missingArtifacts} artifact.`,
      );
    }

    if (!artifact) {
      throw new Error(`No downloadable Developer ID app artifact was found for Xcode Cloud Archive action ${action.id}.`);
    }
    throw new Error(`No downloadable xcarchive artifact was found for Xcode Cloud build run ${buildRun.id}.`);
  }

  if (!selected) {
    if (terminalBuildError) throw terminalBuildError;
    throw new Error(`No Xcode Cloud build run matched tag ${tagName}.`);
  }
  const { buildRun, action, artifacts, artifact, archiveArtifact } = selected;

  logger.error('Selected Xcode Cloud release artifacts:');
  logger.error(JSON.stringify([
    artifactContextSummary({ action, artifact }),
    ...artifacts
      .map((artifactCandidate) => ({ action, artifact: artifactCandidate }))
      .filter(({ artifact: artifactCandidate }) => artifactCandidate.id === archiveArtifact.id)
      .map(artifactContextSummary),
  ], null, 2));

  return {
    product,
    workflow,
    buildRun,
    archiveAction: action,
    artifact,
    archiveArtifact,
  };
}
