---
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

name: ldtx-protoc-gen
description: Generate LDTX's nanopb C headers, C sources, and Swift message adapters.
---

When asked to regenerate nanopb or Swift message outputs, run both generators below
from the repository root. `pipx` and Swift 6.4 with `swift format` must be
installed. The pinned `grpcio-tools` package supplies protoc to both generators.
Swift output is formatted using the repository's
`.swift-format` before writing or checking it.

## Generating pb.h and pb.c files

```sh
pipx run --no-cache --backend pip --with 'protobuf==7.36.2' \
  --with 'grpcio-tools==1.85.0' \
  --path .agents/skills/ldtx-protoc-gen/scripts/ldtx-protoc-gen-c.py \
  -I Protos --error-on-unmatched \
  -D Packages/LDTXCorelibs/Sources/LDTXNanopbGenerated/generated/ Protos/*.proto
```

## pb.swift

```sh
pipx run --no-cache --backend pip --path .agents/skills/ldtx-protoc-gen/scripts/ldtx-protoc-gen-swift.py
```
