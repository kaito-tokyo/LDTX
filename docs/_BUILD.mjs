#!/usr/bin/env node

// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import { spawnSync } from "node:child_process";
import {
  cpSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const docsDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryDirectory = path.dirname(docsDirectory);
const [command] = process.argv.slice(2);

function escapeHTML(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function buildScenarios(outputDirectory) {
  const sourceDirectory = path.join(docsDirectory, "scenarios");
  mkdirSync(outputDirectory, { recursive: true });
  cpSync(
    path.join(docsDirectory, "_lib/gherkin-scenario.js"),
    path.join(outputDirectory, "gherkin-scenario.js"),
  );
  for (const filename of readdirSync(sourceDirectory).sort()) {
    if (!filename.endsWith(".feature")) continue;
    const identifier = filename.split("_")[0];
    const source = readFileSync(path.join(sourceDirectory, filename), "utf8");
    const directory = path.join(outputDirectory, identifier);
    mkdirSync(directory, { recursive: true });
    writeFileSync(path.join(directory, "index.html"), `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${identifier} · LDTX scenarios</title>
  <style>
    :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
    body { max-width: 52rem; margin: 3rem auto; padding: 0 1.5rem; line-height: 1.6; }
    h1 { font-size: 1rem; color: #73839a; letter-spacing: .08em; }
    h2 { line-height: 1.25; }
    pre { white-space: pre-wrap; overflow-wrap: anywhere; }
    section { margin-top: 2rem; }
    li { margin: .6rem 0; }
    table { border-collapse: collapse; }
    td { border: 1px solid #73839a; padding: .3rem .6rem; }
  </style>
  <script type="module" src="../gherkin-scenario.js"></script>
</head>
<body>
  <main>
    <h1>${identifier}</h1>
    <gherkin-scenario><pre>${escapeHTML(source)}</pre></gherkin-scenario>
  </main>
</body>
</html>
`);
  }
}

function buildProtos(outputDirectory) {
  mkdirSync(outputDirectory, { recursive: true });

  const result = spawnSync(
    "protoc",
    [
      "--proto_path=Protos",
      `--doc_out=${path.relative(repositoryDirectory, outputDirectory)}`,
      "--doc_opt=docs/_lib/workspace.tmpl,workspace.html",
      "Protos/envelope.proto",
      "Protos/workspace_v4_definition.proto",
      "Protos/workspace_v4_input_device.proto",
      "Protos/workspace_v4_preferences.proto",
      "Protos/workspace_v4_video_component.proto",
      "Protos/workspace_v4_vfx.proto",
      "Protos/workspace_v4_vision.proto",
      "Protos/workspace_v4_types.proto",
    ],
    { cwd: repositoryDirectory, stdio: "inherit" },
  );

  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }

  const outputPath = path.join(outputDirectory, "workspace.html");
  const output = readFileSync(outputPath, "utf8");
  writeFileSync(outputPath, output.replace(/[ \t]+$/gm, ""));
}

switch (command) {
  case "protos": {
    buildProtos(path.join(docsDirectory, "protos"));
    break;
  }
  case "dist": {
    const distributionDirectory = path.join(docsDirectory, "dist");

    rmSync(distributionDirectory, { force: true, recursive: true });
    mkdirSync(distributionDirectory, { recursive: true });

    for (const directory of ["protos"]) {
      cpSync(
        path.join(docsDirectory, directory),
        path.join(distributionDirectory, directory),
        { recursive: true },
      );
    }
    buildScenarios(path.join(distributionDirectory, "scenarios"));
    break;
  }
  default:
    console.error("Usage: node docs/_BUILD.mjs protos|dist");
    process.exit(1);
}
