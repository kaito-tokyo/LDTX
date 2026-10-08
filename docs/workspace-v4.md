<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Workspace v4

Workspace v4 persists exactly two protobuf documents in each
`.ldtxworkspace` package: `definition.pb` and `preferences.pb`. Its `Info.plist`
contains `CFBundlePackageType` with the value `BNDL`, `LDTXWorkspaceVersion`
with the integer value `4`, and `LDTXWorkspaceBundleVersion` with the string
value `4.0`. `LDTXWorkspaceVersion` identifies the logical Workspace version;
`LDTXWorkspaceBundleVersion` is an extensibility field and does not imply a
compatibility rule. JSON mirrors are not part of the package format. The current
format does not define `Assets` or `Extensions` resources.
`LDTXProtos` owns the in-memory package values, protobuf message types, and the
independent `WorkspaceV4IntegrityValidator` for cross-document Workspace
consistency. It does not add validator methods to generated message types.
`LDTXWorkspaceBundleFormat` owns package reads, writes, and on-disk format
validation, and depends on `LDTXProtos`.

`makeWorkspaceBundleReader(at:)` independently reads
`LDTXWorkspaceVersion` from `Info.plist` and selects a Reader using that logical
Workspace version. It currently selects V4 for the integer value `4`. The
factory does not throw; `WorkspaceBundleReader` carries either a
version-specific Reader or a cause-free failure case. The selected
`WorkspaceBundleReaderV4` uses
`WorkspaceBundleValidatorV4` before decoding either protobuf document. The
validator requires `CFBundlePackageType` to be `BNDL`,
`LDTXWorkspaceVersion` to be integer `4`. The Reader ignores
`LDTXWorkspaceBundleVersion`, including unknown, missing, and non-string values.
New bundles retain the string `4.0` unless a fundamental, incompatible change
requires a new bundle format. Protobuf model changes alone do not require a
bundle-version change. Logical format validation and reference integrity checks
still apply.
The `.v4` case wraps `WorkspaceBundleReaderV4`, which is initialized with the
package URL and reads that package with `read()`. Create a Reader for each read operation; it does not
represent reusable Workspace state. Missing or unsupported packages are
reported as read errors rather than through a separate existence query.
`WorkspaceBundleWriterV4` is likewise initialized with one package URL. Its
failable initializer creates the package directory and writes `Info.plist`;
failure to create or write that metadata returns `nil`. Its
`write(definition:)` and `write(preferences:)` methods atomically write their
respective protobuf documents independently; neither replaces the package or
validates the other document. The persistence coordinator validates the
in-memory bundle before writing both documents. The Writer accepts UUID values
for document identifiers and writes their 16-byte RFC 9562 network byte order
representation into each protobuf envelope. Its `makeExternalID()` operation creates UUIDv7 values
for callers that need new document identifiers.
The Workspace persistence coordinator and CLI orchestrate their document
writes; the Writer does not combine them into a package-level replacement.
Shared bundle values are defined by
`LDTXWorkspaceBundleFormat`; read and write operations propagate Foundation and
Protobuf errors. `WorkspaceLockService` belongs to Workspace runtime
coordination: the Runtime retains the package lock for the open-window lifetime,
while CLI commands hold it for the duration of an operation. The Reader and
Writer do not acquire locks.

The application selects the V4 runtime from this protobuf-only layout before
decoding either document. A package containing either legacy JSON mirror is
treated as a non-V4 package, including when its protobuf documents are also
present; it is not partially opened as V4.

Each document is wrapped in its corresponding envelope, which records its
UUIDv7 `external_id` and a `WorkspaceDefinitionV4` or `WorkspacePreferencesV4`
payload. The protobuf message comments are the normative format specification;
the rendered reference is [workspace.html](protos/workspace.html).

The CLI creates Workspace v4 packages from protobuf JSON when needed:

```sh
ldtx workspace create Unite-20260910.ldtxworkspace --json definition.json \
  --preferences-json preferences.json
```

`ldtx workspace dump` prints the stored v4 Program layer references, and
`ldtx workspace validate` verifies that both persisted documents are valid v4
envelopes. The application opens v4 packages through the owning
`WorkspaceWindowRuntime`, directly from the v4 protobuf documents. It persists the
Workspace definition and mutable preferences directly through the two v4
envelopes.

## Audio devices, VFX Sources, and OCR

The Workspace model stores audio inputs in `audio_devices`. Video inputs are
VFX Source Video Components; physical camera assignments are app-local and keyed
by the VFX Source internal ID. Sources may remain unassigned. Multiple Sources
can share a camera while applying their own effects. Programs reference only
Video Components, and the optional PTS master references a VFX Source.

OCR Visions reference `video_component_internal_id` and analyze the component
after effects, before Program cropping, placement, visibility, and compositing.
Camera components use their input resolution, Clock uses its Landscape-based
size, and other generated components use 1920 by 1080 pixels. The ROI is applied
to that component image. OCR does not require a selected Program or active output.
A referenced component cannot be deleted until its Program, OCR, and PTS
references are removed.

No migration or compatibility adapter is provided for removed model fields.
The bundle-version value is not a compatibility gate.
Removed protobuf fields are reserved, and their numbers are not reused.

On macOS 27, Fast recognition with language correction disabled uses Accurate
recognition to avoid a reproduced TextRecognition framework crash. The saved
recognition preferences remain unchanged, and the Inspector displays this
behavior. Recognition results and failures appear in the OCR Inspector.
