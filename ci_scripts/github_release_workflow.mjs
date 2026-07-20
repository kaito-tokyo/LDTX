// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';

import { releaseWatchTimestamp, sleep } from './xcode_cloud_release.mjs';

const execFileAsync = promisify(execFile);

async function runCommand(command, args, { cwd = process.cwd(), env = process.env } = {}) {
  try {
    return await execFileAsync(command, args, {
      cwd,
      env,
      maxBuffer: 10 * 1024 * 1024,
    });
  } catch (error) {
    const stderr = error?.stderr?.trim();
    const detail = stderr ? `: ${stderr}` : '';
    throw new Error(`${command} ${args.join(' ')} failed${detail}`);
  }
}

/**
 * Verifies that the tag exists locally.
 *
 * @param {string} tagName
 * @param {{ cwd?: string, env?: NodeJS.ProcessEnv }} [options]
 * @returns {Promise<boolean>}
 */
export async function hasLocalTag(tagName, options) {
  try {
    await runCommand('git', ['rev-parse', '-q', '--verify', `refs/tags/${tagName}`], options);
    return true;
  } catch {
    return false;
  }
}

/**
 * Resolves the commit SHA for a local tag.
 *
 * @param {string} tagName
 * @param {{ cwd?: string, env?: NodeJS.ProcessEnv }} [options]
 * @returns {Promise<string>}
 */
export async function gitTagSHA(tagName, options) {
  const { stdout } = await runCommand('git', ['rev-list', '-n', '1', tagName], options);
  return stdout.trim();
}

/**
 * Dispatches the GitHub Actions release workflow for the given tag.
 *
 * @param {object} options
 * @param {string} [options.ldtxBuildRunId]
 * @param {string} [options.ldtxTinyBuildRunId]
 * @param {string} options.tagName
 * @param {string} [options.workflow='release.yml']
 * @param {{ error?: (message: string) => void }} [options.logger=console]
 * @param {string} [options.cwd]
 * @param {NodeJS.ProcessEnv} [options.env]
 * @returns {Promise<void>}
 */
export async function dispatchReleaseWorkflow({
  ldtxBuildRunId,
  ldtxTinyBuildRunId,
  tagName,
  workflow = 'release.yml',
  logger = console,
  cwd,
  env,
}) {
  logger.error(`[${releaseWatchTimestamp()}] Dispatching ${workflow} for ${tagName}`);
  const args = ['workflow', 'run', workflow, '--ref', tagName];
  if (ldtxBuildRunId) {
    args.push('-f', `ldtx_build_run_id=${ldtxBuildRunId}`);
  }
  if (ldtxTinyBuildRunId) {
    args.push('-f', `ldtx_tiny_build_run_id=${ldtxTinyBuildRunId}`);
  }
  await runCommand('gh', args, { cwd, env });
}

/**
 * Returns recent GitHub Actions workflow runs as plain objects.
 *
 * @param {object} options
 * @param {string} [options.event='workflow_dispatch']
 * @param {number} [options.limit=20]
 * @param {string} [options.workflow='release.yml']
 * @param {string} [options.cwd]
 * @param {NodeJS.ProcessEnv} [options.env]
 * @returns {Promise<Array<Record<string, unknown>>>}
 */
export async function listWorkflowRuns({
  event = 'workflow_dispatch',
  limit = 20,
  workflow = 'release.yml',
  cwd,
  env,
} = {}) {
  const { stdout } = await runCommand(
    'gh',
    [
      'run',
      'list',
      '--workflow',
      workflow,
      '--event',
      event,
      '--json',
      'databaseId,createdAt,displayTitle,headBranch,headSha,url',
      '--limit',
      String(limit),
    ],
    { cwd, env },
  );
  return JSON.parse(stdout || '[]');
}

/**
 * Selects the workflow run that most likely belongs to a tag-triggered manual
 * dispatch issued after the given timestamp.
 *
 * @param {object} options
 * @param {string} options.dispatchedAfter
 * @param {Array<Record<string, unknown>>} options.runs
 * @param {string} options.tagName
 * @param {string} options.tagSHA
 * @returns {Record<string, unknown>|undefined}
 */
export function selectDispatchedWorkflowRun({ dispatchedAfter, runs, tagName, tagSHA }) {
  const cutoff = Date.parse(dispatchedAfter);

  return runs
    .filter((run) => {
      const createdAt = Date.parse(String(run.createdAt ?? ''));
      const displayTitle = String(run.displayTitle ?? '');
      const headBranch = String(run.headBranch ?? '');
      const headSHA = String(run.headSha ?? '');
      return (
        headSHA === tagSHA &&
        Number.isFinite(createdAt) &&
        createdAt >= cutoff &&
        (headBranch === tagName || displayTitle.includes(tagName))
      );
    })
    .sort((left, right) => Date.parse(String(right.createdAt ?? '')) - Date.parse(String(left.createdAt ?? '')))[0];
}

/**
 * Polls GitHub Actions until the release workflow run dispatched for the tag
 * is visible in `gh run list`.
 *
 * @param {object} options
 * @param {string} options.dispatchedAfter
 * @param {string} options.tagName
 * @param {string} options.tagSHA
 * @param {number} [options.intervalSeconds=10]
 * @param {{ error?: (message: string) => void }} [options.logger=console]
 * @param {number} [options.maxAttempts=30]
 * @param {string} [options.workflow='release.yml']
 * @param {string} [options.cwd]
 * @param {NodeJS.ProcessEnv} [options.env]
 * @returns {Promise<Record<string, unknown>>}
 */
export async function waitForDispatchedWorkflowRun({
  dispatchedAfter,
  tagName,
  tagSHA,
  intervalSeconds = 10,
  logger = console,
  maxAttempts = 30,
  workflow = 'release.yml',
  cwd,
  env,
}) {
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const runs = await listWorkflowRuns({ workflow, cwd, env });
    const run = selectDispatchedWorkflowRun({
      dispatchedAfter,
      runs,
      tagName,
      tagSHA,
    });
    if (run) {
      return run;
    }

    logger.error(
      `[${releaseWatchTimestamp()}] Waiting for ${workflow} run for ${tagName} to appear (attempt ${attempt}/${maxAttempts})`,
    );
    await sleep(intervalSeconds * 1000);
  }

  throw new Error(`Could not find the dispatched ${workflow} run for ${tagName}.`);
}

/**
 * Streams `gh run watch` output for the given run ID until completion.
 *
 * @param {object} options
 * @param {number|string} options.runId
 * @param {number} [options.intervalSeconds=10]
 * @param {string} [options.cwd]
 * @param {NodeJS.ProcessEnv} [options.env]
 * @returns {Promise<void>}
 */
export async function watchWorkflowRun({ runId, intervalSeconds = 10, cwd, env }) {
  await new Promise((resolve, reject) => {
    const child = spawn(
      'gh',
      ['run', 'watch', String(runId), '--compact', '--exit-status', '--interval', String(intervalSeconds)],
      {
        cwd,
        env,
        stdio: 'inherit',
      },
    );

    child.on('error', reject);
    child.on('exit', (code) => {
      if (code === 0) {
        resolve();
        return;
      }

      reject(new Error(`gh run watch ${runId} failed with exit code ${code ?? 'unknown'}`));
    });
  });
}
