// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import test from 'node:test';

import { buildRunMatchesTag, findArchiveBuild } from './notarized-build.mjs';

const expected = {
  tagName: 'v0.1.43',
  gitRef: 'refs/tags/v0.1.43',
  commitSha: 'release-commit',
};

function buildRunContext({ commitSha = 'release-commit', reference } = {}) {
  return {
    buildRun: {
      attributes: {
        sourceCommit: { commitSha },
        ...(reference === undefined ? {} : { sourceTag: reference }),
      },
    },
    sourceBranchOrTagChecked: true,
  };
}

test('matches an exact commit and tag', () => {
  assert.equal(buildRunMatchesTag(
    buildRunContext({ reference: 'v0.1.43' }),
    expected,
  ), true);
});

test('matches an exact commit when the API omits reference metadata', () => {
  assert.equal(buildRunMatchesTag(buildRunContext(), expected), true);
});

test('rejects an explicit different tag even when the commit matches', () => {
  assert.equal(buildRunMatchesTag(
    buildRunContext({ reference: 'v0.1.42' }),
    expected,
  ), false);
});

test('rejects a different commit even when the tag matches', () => {
  assert.equal(buildRunMatchesTag(
    buildRunContext({ commitSha: 'other-commit', reference: 'v0.1.43' }),
    expected,
  ), false);
});

test('matches tag metadata supplied by the related resource', () => {
  const context = buildRunContext();
  context.sourceBranchOrTag = { attributes: { name: 'refs/tags/v0.1.43' } };

  assert.equal(buildRunMatchesTag(context, expected), true);
});

test('rejects different tag metadata supplied by the related resource', () => {
  const context = buildRunContext();
  context.sourceBranchOrTag = { attributes: { name: 'refs/tags/v0.1.42' } };

  assert.equal(buildRunMatchesTag(context, expected), false);
});

test('rejects missing reference metadata when the related-resource lookup failed', () => {
  const context = buildRunContext();
  context.sourceBranchOrTagChecked = false;
  context.sourceBranchOrTagError = 'GET sourceBranchOrTag failed with 503';

  assert.equal(buildRunMatchesTag(context, expected), false);
});

test('finds release artifacts when build-run reference metadata is absent', async () => {
  const buildRun = buildRunContext().buildRun;
  buildRun.id = 'build-run';
  buildRun.attributes.completionStatus = 'SUCCEEDED';
  const archiveAction = {
    id: 'archive-action',
    attributes: { name: 'Archive - macOS', completionStatus: 'SUCCEEDED' },
  };
  const developerIdArtifact = {
    id: 'developer-id',
    attributes: {
      downloadUrl: 'https://example.com/developer-id.zip',
      fileName: 'LDTX developer-id.zip',
      fileType: 'ARCHIVE_EXPORT',
    },
  };
  const archiveArtifact = {
    id: 'archive',
    attributes: {
      downloadUrl: 'https://example.com/LDTX.xcarchive.zip',
      fileName: 'LDTX.xcarchive.zip',
      fileType: 'ARCHIVE',
    },
  };
  const api = {
    async products() {
      return [{ id: 'product', attributes: { name: 'LDTX' } }];
    },
    async productWorkflows() {
      return [{ id: 'workflow', attributes: { name: 'On push tag - LDTX' } }];
    },
    async *workflowBuildRunPages() {
      yield [buildRun];
    },
    async relatedResource() {
      return undefined;
    },
    async buildActions() {
      return [archiveAction];
    },
    async actionArtifacts() {
      return [developerIdArtifact, archiveArtifact];
    },
  };

  const result = await findArchiveBuild({
    api,
    productName: 'LDTX',
    workflowName: 'On push tag - LDTX',
    ...expected,
    logger: { error() {}, warn() {} },
  });

  assert.equal(result.buildRun, buildRun);
  assert.equal(result.artifact, developerIdArtifact);
  assert.equal(result.archiveArtifact, archiveArtifact);
});
