#!/usr/bin/env node

// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import { spawnSync } from "node:child_process";
import {
  cpSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const docsDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryDirectory = path.dirname(docsDirectory);
const [command] = process.argv.slice(2);

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
    break;
  }
  default:
    console.error("Usage: node docs/_BUILD.mjs protos|dist");
    process.exit(1);
}
