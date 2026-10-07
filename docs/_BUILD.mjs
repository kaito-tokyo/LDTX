#!/usr/bin/env node

// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import { spawnSync } from "node:child_process";
import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { tmpdir } from "node:os";
import { renderProtobufReference } from "./_lib/protobuf-reference.mjs";

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

  const temporaryDirectory = mkdtempSync(path.join(tmpdir(), "ldtx-proto-docs-"));
  try {
    const descriptorPath = path.join(temporaryDirectory, "workspace.pb");
    const result = spawnSync(
      "npx",
      [
        "--yes",
        "protoc@36.0.0",
        "--proto_path=Protos",
        "--include_source_info",
        `--descriptor_set_out=${descriptorPath}`,
        ...readdirSync(path.join(repositoryDirectory, "Protos"))
          .filter((name) => name === "envelope.proto" || /^workspace_v4_.*\.proto$/.test(name))
          .sort()
          .map((name) => `Protos/${name}`),
      ],
      { cwd: repositoryDirectory, stdio: "inherit" },
    );
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`protoc failed with status ${result.status}`);
    writeFileSync(
      path.join(outputDirectory, "workspace.html"),
      renderProtobufReference(readFileSync(descriptorPath)),
    );
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
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
