---
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

name: generate-nanopb-protos
description: Regenerate or change LDTX's nanopb C headers, C sources, and Swift message adapters.
---

`protoc` 36.2 or higher and `pipx` must be installed. `Vendors/nanopb` submodule must be populated.

## Generating pb.h and pb.c files

```sh
pipx run --spec 'protobuf==7.36.2' python Vendors/nanopb/generator/nanopb_generator.py -I Protos --error-on-unmatched -D Packages/LDTXCorelibs/Sources/LDTXNanopbGenerated/generated/ Protos/*.proto
```

## pb.swift

```sh
proto_swift=$(mktemp -d "${TMPDIR:-/tmp}/ldtx-proto-swift.XXXXXX")
protoc -I Protos --include_imports --include_source_info \
  --descriptor_set_out="$proto_swift/schemas.pb" Protos/*.proto

pipx run --backend pip --path .agents/skills/generate-nanopb-protos/scripts/generate-nanopb-headers.py \
  --descriptor "$proto_swift/schemas.pb"
```
