<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
SPDX-License-Identifier: Apache-2.0
-->

# Workspace message generation

`Protos/*.proto` is the schema source of truth. Run protoc externally, then pass
its binary FileDescriptorSet to the Python generator. There is no Command Plugin,
SwiftSyntax dependency, or separate Swift package for the generator.

From the repository root, using protoc 36.2:

```sh
python3 -m venv /tmp/ldtx-proto-generator
/tmp/ldtx-proto-generator/bin/pip install -r Tools/GenerateNanopbProtos/requirements.txt
swift package --package-path Packages/Corelibs resolve
mkdir -p /tmp/ldtx-proto-input

protoc -I Protos --include_imports --include_source_info \
  --descriptor_set_out=/tmp/ldtx-proto-input/schemas.pb Protos/*.proto
protoc -I Packages/Corelibs/.build/checkouts/nanopb/generator/proto \
  --python_out=/tmp/ldtx-proto-input nanopb.proto

/tmp/ldtx-proto-generator/bin/python Tools/GenerateNanopbProtos/generate.py \
  --descriptor /tmp/ldtx-proto-input/schemas.pb
/tmp/ldtx-proto-generator/bin/python Tools/GenerateNanopbProtos/generate.py \
  --descriptor /tmp/ldtx-proto-input/schemas.pb --check
```

All schemas must be supplied. The descriptor is an intermediate file and should
not be committed. The helper `nanopb_pb2.py` must be generated alongside it.
The official generator is taken from `Packages/Corelibs/.build/checkouts/nanopb`; pass
`--nanopb-root CHECKOUT` for another SwiftPM scratch path. It must match the
runtime pin (nanopb 0.4.9.2, SwiftPM tag 0.4.92).

The generator never invokes protoc. It sends a `CodeGeneratorRequest` to
nanopb's official `nanopb_generator.py --protoc-plugin` entry point and reads
the `CodeGeneratorResponse`. `NANOPB_PB2_NO_REBUILD=1` prevents the upstream
loader from compiling its helper implicitly. Bytecode writes are disabled in
that subprocess, leaving the SwiftPM checkout untouched. Python protobuf reads
the descriptor; no custom `.proto` parser or descriptor wire decoder is needed.
`--check` fails if any output differs, without modifying files. Updating sources
uses `apply_patch`, which must be on PATH. All outputs are prepared before the
patch is applied. Handwritten extensions in `Messages/` are preserved.

## Generated sources and runtime

The tool emits Swift models and field adapters into
`Packages/Corelibs/LDTXProtos/Messages`. The official nanopb generator produces
the C structs, FIELDLISTs and runtime descriptors under `NanopbMessages`.
Its options are `type:FT_CALLBACK`, `no_unions:true`, `callback_datatype:"void *"`
and `callback_function:"ldtx_nanopb_field_callback"`. Our wrapper only adds the
umbrella header and `StorageChecks.c`, which checks that every C struct
contains only callback context pointers, not copies of Swift payloads.

The supported schema profile is the repository's Edition 2024 messages with
explicit presence, defaults, nested messages/enums, maps and oneofs. These
restrictions apply to our Swift adapter layer; C generation uses upstream's implementation.
Normal application builds require neither Python nor protoc.

`pb_decode` performs dispatch, unknown-field skipping and framing; `pb_encode`
and `pb_encode_submessage` handle encoding traversal and submessage sizing.
Strings decode into Swift String's initialization buffer and bytes into Data.
Swift handles oneof replacement/merge semantics, presence, defaults and ProtoJSON.
Unknown payload fields are discarded. Both packed and expanded repeated scalar
inputs are accepted; output uses expanded fields. Map output is ordered by key.

LDTXProtos is a target in the Corelibs local package. Its shared manifest owns the runtime nanopb
pin and C/Swift configuration macros. Message tests remain in the root
`LDTXCorelibsTests` target. YouTube IPC remains independent, using binary PropertyLists.
