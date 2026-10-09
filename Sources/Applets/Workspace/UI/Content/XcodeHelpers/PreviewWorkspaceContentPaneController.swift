// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
  import LDTXProtos
  import AppKit

  import LDTXProgramRuntime
  import LDTXVideoRendering
  import LDTXWorkspaceAppletModel
  import MetalKit

  @MainActor
  final class PreviewWorkspaceContentPaneController: NSViewController {
    private let pane: WorkspaceContentPane
    private var didConfigure = false

    init(hasProgram: Bool) {
      let service = WorkspaceSidebarPreviewFixtures.makeUIState()
      var secondInput = Ldtx_Workspace_V4_AudioInputDevice()
      secondInput.internalID = 11
      secondInput.displayName = "Game Audio"
      service.definition.audioDevices.append(secondInput)
      service.preferences.audioChannelGainsDecibels[2] = .with {
        $0.set(num: -60, den: 10)
      }
      if hasProgram {
        var program = Ldtx_Workspace_V4_ProgramDefinition()
        program.internalID = 100
        program.displayName = "Studio"
        service.definition.programs = [program]
        for (index, target) in [WorkspaceCanvasTarget.landscape, .portrait].enumerated() {
          var preferences = Ldtx_Workspace_V4_ProgramPreferences()
          preferences.videoLayerInternalIds = index == 0 ? [4, 3, 8] : [3, 8]
          preferences.audioMasterVolumeDecibels =
            index == 0
            ? .with {
              $0.set(num: -30, den: 10)
            }
            : .with {
              $0.set(num: -60, den: 10)
            }
          preferences.audioChannelMuted[11] = index == 1
          for id: UInt64 in [3, 4, 8] {
            var transform = Ldtx_Workspace_V4_BasicTransform()
            transform.scaleX = .with {
              $0.set(num: 1, den: 1)
            }
            transform.scaleY = .with {
              $0.set(num: 1, den: 1)
            }
            preferences.videoLayerTransforms[id] = transform
          }
          preferences.videoLayerHidden[8] = true
          service.preferences[keyPath: target.preferences][100] = preferences
        }
      }
      let delegate = PreviewDelegate()
      let pairedPreview = ProgramCanvasPairedPreview(
        device: delegate.device, delegate: delegate,
        onSelectLandscape: { service.selectedAudioMix = .landscape },
        onSelectPortrait: { service.selectedAudioMix = .portrait })
      pairedPreview.metalView.isPaused = true
      pairedPreview.metalView.enableSetNeedsDisplay = true
      pane = WorkspaceContentPane(storeService: service, pairedPreview: pairedPreview)
      super.init(nibName: nil, bundle: nil)
      addChild(pane)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
      view = NSView()
      pane.view.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(pane.view)
      NSLayoutConstraint.activate([
        view.widthAnchor.constraint(equalToConstant: 480),
        view.heightAnchor.constraint(equalToConstant: 560),
        pane.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        pane.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        pane.view.topAnchor.constraint(equalTo: view.topAnchor),
        pane.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
    }

    override func viewDidAppear() {
      super.viewDidAppear()
      guard !didConfigure else { return }
      didConfigure = true
      pane.configureAfterEstablished()
      pane.pairedPreview.metalView.needsDisplay = true
    }

    private final class PreviewDelegate: NSObject, MTKViewDelegate {
      let device = MTLCreateSystemDefaultDevice()
      private let commandQueue: MTLCommandQueue?
      private let pipeline: MTLComputePipelineState?
      private let emptyLuma: MTLTexture?
      private let emptyChroma: MTLTexture?

      override init() {
        commandQueue = device?.makeCommandQueue()
        pipeline = device.flatMap { try? VideoCompositor.makePreviewRegionPipeline(device: $0) }
        emptyLuma = device?.makeTexture(
          descriptor: .texture2DDescriptor(
            pixelFormat: .r8Uint, width: 1, height: 1, mipmapped: false))
        emptyChroma = device?.makeTexture(
          descriptor: .texture2DDescriptor(
            pixelFormat: .rg8Uint, width: 1, height: 1, mipmapped: false))
        super.init()
      }

      func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
      }

      func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
          let command = commandQueue?.makeCommandBuffer(),
          let pipeline, let emptyLuma, let emptyChroma
        else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.5, 0.5, 0.5, 1)
        guard let clear = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        clear.endEncoding()
        guard let encoder = command.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(emptyLuma, index: 0)
        encoder.setTexture(emptyChroma, index: 1)
        encoder.setTexture(drawable.texture, index: 2)
        let regions = ProgramPairPreviewRegions(
          drawable: CGSize(width: drawable.texture.width, height: drawable.texture.height),
          landscapeSize: CGSize(width: 16, height: 9),
          portraitSize: CGSize(width: 9, height: 16))
        var state: UInt32 = 0
        encoder.setBytes(&state, length: MemoryLayout.size(ofValue: state), index: 1)
        for rect in [regions.landscape, regions.portrait] where rect.width > 0 && rect.height > 0 {
          var region = SIMD4<UInt32>(
            UInt32(rect.minX), UInt32(rect.minY), UInt32(rect.width), UInt32(rect.height))
          encoder.setBytes(&region, length: MemoryLayout.size(ofValue: region), index: 0)
          encoder.dispatchThreads(
            MTLSize(width: Int(rect.width), height: Int(rect.height), depth: 1),
            threadsPerThreadgroup: MTLSize(
              width: pipeline.threadExecutionWidth,
              height: max(
                1, pipeline.maxTotalThreadsPerThreadgroup / pipeline.threadExecutionWidth),
              depth: 1))
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
      }
    }
  }
#endif
