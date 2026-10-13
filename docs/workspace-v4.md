<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Workspace v4

Workspace v4 persists three protobuf documents in each
`.ldtxworkspace` package: `definition.pb`, `preferences.pb`, and
`output_settings.pb`. Its `Info.plist`
contains `CFBundlePackageType` with the value `BNDL`, `LDTXWorkspaceVersion`
with the integer value `4`, and `LDTXWorkspaceBundleVersion` with the string
value `4.0`. `LDTXWorkspaceVersion` identifies the logical Workspace version;
`LDTXWorkspaceBundleVersion` is an extensibility field and does not imply a
compatibility rule. JSON mirrors are not part of the package format. The current
format does not define `Assets` or `Extensions` resources.
Imported Core ML models are stored at
`VisionModels/<model_internal_id>/<original basename>.{mlmodel|mlpackage}`.
`model_internal_id` identifies a model resource independently of its referencing
Vision. Zero means no assignment. Reader selects the first supported basename in
lexicographic order within each model directory. WorkspaceV4Bundle and StateService
hold `visionModels: [Int64: URL]`, including retained historical models.

Choosing a new model allocates its ID immediately and records its source URL.
Reselecting the same current URL preserves the ID. A Snapshot captures source URLs,
not a copy of the file bytes. Writer copies native model files or package trees
before writing protobuf documents, without assigning IDs or modifying references.
Saving preserves the source URLs in Document and StateService. Reader constructs
bundle-local URLs when the package is read again. Inference uses the runtime
copy's bundle-local URL and matches the saved model ID and Vision settings rather
than requiring the editing source URL to equal the runtime URL.
Existing models are not rewritten or deleted. Clearing an assignment sets
`model_internal_id` to zero and retains past resources. Automatic pruning is not
part of saving.

Importing a model does not compile it or execute inference.

`LDTXProtos` owns protobuf message types and the
independent `WorkspaceV4IntegrityValidator` for cross-document Workspace
consistency. It does not add validator methods to generated message types.
`LDTXWorkspaceBundleFormat` owns WorkspaceV4Bundle, package reads, writes, and on-disk format
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
`WorkspaceBundleWriterV4` supports both individual document writes and complete
WorkspaceV4Bundle writes. Its destination-independent initializer performs no
filesystem work; `write(_:to:)` validates the bundle and serializes all three
envelopes before creating metadata, placing models, and writing the documents.
Existing model revisions and unknown package resources are preserved.
WorkspaceDocument defines inline Reader and Writer wrappers that choose their
async execution behavior and delegate package I/O to Corelibs. WriterV4 has no
SwiftUI dependency or retroactive DocumentWriter conformance.

For individual document writes, WriterV4 can be initialized with a package URL. Its
failable initializer creates the package directory and writes `Info.plist`;
failure to create or write that metadata returns `nil`. Its
`write(definition:)` and `write(preferences:)` methods atomically write their
respective protobuf documents independently; neither replaces the package or
validates the other document. Destination URL accessors throw if the Writer has
no bound package URL. The Writer accepts UUID values
for document identifiers and writes their 16-byte RFC 9562 network byte order
representation into each protobuf envelope. Its `makeExternalID()` operation creates UUIDv7 values
for callers that need new document identifiers.
Individual writes remain available for CLI operations. DocumentWriter delegates
complete-bundle saves to WriterV4 at the framework-supplied staging destination;
WriterV4 does not replace the entire package directory.
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
