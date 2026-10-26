<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
SPDX-License-Identifier: Apache-2.0
-->

# Target dependencies

Package targets are defined in `Packages/LDTXCorelibs/Package.swift`. Native macOS
targets are defined in `project/*.yml`. The diagrams below show the boundaries
affected by Workspace UI and message encoding; they omit unrelated targets and
system frameworks. Arrows point from a consumer to its dependency.

## Workspace presentation

```mermaid
flowchart TD
    Controller[LDTXWorkspaceAppletController] --> UI[LDTXWorkspaceAppletUI]
    Controller --> Runtime[LDTXProgramRuntime]
    Controller --> Devices[LDTXDeviceRegistry]
    Controller --> Vision[LDTXVision]
    Controller --> Contract[LDTXWorkspaceAppletInterface]
    UI --> Contract
    UI --> Model[LDTXWorkspaceAppletModel]
    UI --> Protos[LDTXProtos]
    UI --> Bundles[LDTXWorkspaceBundleFormat]
    UI --> Program[LDTXProgram]
    UI --> MacValues[LDTXProtosMacOSExtra]
    UI --> Views[LDTXAppletSupport / LDTXRichText / LDTXVariableMacro]
    Contract --> Model
    Contract --> Protos
    Model --> Program
    Program --> Protos
    Runtime --> Contract
    Devices --> Contract
    Devices --> Capture[LDTXCapture]
    Capture --> Protos
    RTMPS[LDTXYouTubeRTMPS] --> Protos
```

Workspace UI consumes device-discovery, audio-peak and preview-accessibility
contracts rather than concrete services. The controller supplies the existing
runtime instances. The MTKView, preview delegate, Window/Document ownership and
AppDelegate composition root retain their existing lifetimes.

Vision model metadata is loaded through WorkspaceRuntimeActions. The coordinator
calls the classifier service and projects the result into a Foundation-only
WorkspaceVisionModelInformation value. UI does not import Vision or CoreML.
Camera/audio device descriptions, RTMPS configuration and transport values,
output actions and audio-master selection also live in Protos; their implementations
remain in the capture, discovery, streaming and audio-engine modules.

UI still uses the lightweight Corelibs bundle values and document IO, model/editing
values, macOS value conversions and reusable text/view components. It has no
direct target dependency on ProgramRuntime, DeviceRegistry, Capture, Vision,
BackgroundSegmentation, VideoComposition, VideoRendering, TaskQueue, YouTube or
YouTubeRTMPS. Device previews use presentation fixtures; GPU preview
assembly is compiled in the controller target.

## Message encoding

```mermaid
flowchart TD
    Protos[LDTXProtos] --> SwiftRuntime[LDTXNanopb]
    Protos --> Messages[LDTXNanopbMessages]
    SwiftRuntime --> Support[LDTXNanopbSupport]
    SwiftRuntime --> nanopb
    Messages --> Support
    Messages --> nanopb
    Support --> nanopb
```

LDTXNanopb owns the schema-independent Swift reader/writer, message protocol and
JSON scalar helpers. LDTXNanopbSupport owns the synchronous C callback context and
wire-type validation. Neither target depends on generated Workspace messages.
LDTXNanopbMessages contains only the official generator's schema-specific C
definitions, umbrella header and storage assertions. LDTXProtos owns generated
Swift models, data contracts and their schema-specific extensions.

Internal cross-target adapter operations use Swift package access. C descriptor
types are not promoted into the public message API. Corelibs still exports one
dynamic product so these implementation targets are linked once per process.

## Verification

Build the schema-independent runtime and the shared tests independently:

```sh
swift build --package-path Packages/LDTXCorelibs --target LDTXNanopb
swift test --package-path Packages/LDTXCorelibs
```

The LDTXWorkspaceAppletUI scheme can be built without the runtime implementation
targets. Run UI component tests for document/editing behavior, and the existing
preview, device discovery, output, CLI and XPC tests for integration behavior.
