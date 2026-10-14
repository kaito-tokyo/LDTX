// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXWorkspaceBundleFormat
import Testing

@Suite("Workspace V4 integrity validation")
struct WorkspaceBundleValidatorV4UnitTestSuite {
  @Test func channelGainsUseTheSupportedDecibelRange() throws {
    let definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
      $0.displayName = "Test"
      $0.audioDevices = [.with {
        $0.internalID = 1
        $0.displayName = "Microphone"
      }]
    }
    var bundle = WorkspaceV4Bundle(definition: definition, preferences: .init())
    for (numerator, valid): (Int32, Bool) in [(-801, false), (-800, true),
      (0, true), (200, true), (201, false), (1000, false)] {
      bundle.preferences.audioChannelGainsDecibels[1, default: .init()].set(num: numerator, den: 10)
      let bytes = try bundle.preferences.serializedData()
      let issues = WorkspaceBundleValidatorV4.validationIssues(in: bundle)
      #expect(issues.contains { $0.error == .invalidAudioChannelGain } == !valid)
      if !valid {
        #expect(issues.contains {
          $0.error == .invalidAudioChannelGain
            && $0.path == "preferences.audio_channel_gains_decibels[1]"
        })
      }
      #expect(try bundle.preferences.serializedData() == bytes)
    }
  }

  @Test func roiDefaultsUseInputPixelsWithoutMutatingStoredPresence() throws {
    var roi = Ldtx_Workspace_V4_VisionRegionOfInterest()
    let full = try roi.resolved(inputSize: (1920, 1080))
    #expect(full.x.num == 0 && full.x.den == 1920)
    #expect(full.y.num == 0 && full.y.den == 1080)
    #expect(full.width.num == 1920 && full.width.den == 1920)
    #expect(full.height.num == 1080 && full.height.den == 1080)
    roi.width.set(num: 1, den: 2)
    roi.width.clearDen()
    let bytes = try roi.serializedData()
    #expect(try roi.resolved(inputSize: (1920, 1080)).width.double == 1.0 / 1920)
    try WorkspaceBundleValidatorV4.validateRegionOfInterest(roi, inputSize: (1920, 1080))
    #expect(try roi.serializedData() == bytes)
    roi.width.clearNum()
    roi.width.den = 1920
    #expect(try roi.resolved(inputSize: (1920, 1080)).width.double == 1)
    roi.width.den = 0
    #expect(throws: WorkspaceV4ValidationError.self) {
      try WorkspaceBundleValidatorV4.validateRegionOfInterest(roi, inputSize: (1920, 1080))
    }
  }

  @Test func bundleValidationUsesReferencedInputSizeForAbsentRoiFields() throws {
    let definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
      $0.videoComponents = [.with {
        $0.vfxSource = .with {
          $0.internalID = 1
          $0.displayName = "Camera"
          $0.deviceWidth = 1920
          $0.deviceHeight = 1080
        }
      }]
      $0.visions = [.with {
        $0.ldtxSceneDetectorVision = .with {
          $0.internalID = 3
          $0.displayName = "Detector"
          $0.videoComponentInternalID = 1
          $0.regionOfInterest.width.num = 320
          $0.regionOfInterest.height.num = 180
        }
      }]
    }
    try WorkspaceBundleValidatorV4.validate(definition)
    let roi = definition.visions[0].ldtxSceneDetectorVision.regionOfInterest
    let resolved = try roi.resolved(inputSize: (1920, 1080))
    #expect(resolved.width.double == 1.0 / 6 && resolved.height.double == 1.0 / 6)
    #expect(!roi.width.hasDen && !roi.height.hasDen)
  }

  @Test func reportsMissingLayerAtEachReferencingMap() {
    let definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
      $0.programs = [
        .with {
          $0.internalID = 1
          $0.displayName = "Program"
        }
      ]
    }
    var bundle = WorkspaceV4Bundle(definition: definition, preferences: .init())
    bundle.preferences.landscapeProgramPreferences[1, default: .init()].videoLayerHidden[3] = true
    bundle.preferences.landscapeProgramPreferences[1, default: .init()].videoLayerTransforms[5] = .init()
    bundle.preferences.landscapeProgramPreferences[1, default: .init()].videoLayerHidden[7] = true
    bundle.preferences.landscapeProgramPreferences[1, default: .init()].videoLayerTransforms[7] = .init()
    let paths = WorkspaceBundleValidatorV4.validationIssues(in: bundle).filter {
      if case .missingVideoLayer = $0.error { return true }
      return false
    }.map(\.path).sorted()
    #expect(paths == [
      "preferences.Landscape[1].video_layer_hidden[3]",
      "preferences.Landscape[1].video_layer_hidden[7]",
      "preferences.Landscape[1].video_layer_transforms[5]",
      "preferences.Landscape[1].video_layer_transforms[7]",
    ])
  }

  @Test func rejectsUnsupportedAndZeroSizedSceneDetectorInputs() {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.visions = [
      .with {
        $0.ldtxSceneDetectorVision = .with {
          $0.internalID = 3
          $0.displayName = "Detector"
          $0.videoComponentInternalID = 1
        }
      }
    ]
    definition.videoComponents = [
      .with {
        $0.solidColorFill = .with {
          $0.internalID = 1
          $0.displayName = "Fill"
        }
      }
    ]
    var bundle = WorkspaceV4Bundle(definition: definition, preferences: .init())
    #expect(
      WorkspaceBundleValidatorV4.validationIssues(in: bundle).contains {
        $0.error == .unsupportedVisionInput
      })
    bundle.definition.videoComponents = [
      .with {
        $0.vfxSource = .with {
          $0.internalID = 1
          $0.displayName = "Camera"
          $0.deviceWidth = 0
          $0.deviceHeight = 1080
        }
      }
    ]
    #expect(
      WorkspaceBundleValidatorV4.validationIssues(in: bundle).contains {
        $0.error == .invalidVisionInputSize
      })
    bundle.definition.videoComponents[0].vfxSource.deviceWidth = 1920
    #expect(
      !WorkspaceBundleValidatorV4.validationIssues(in: bundle).contains {
        $0.error == .invalidVisionInputSize
      })
  }

  @Test func rejectsMasterVolumeOutsideSupportedRange() {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [
      .with {
        $0.internalID = 1
        $0.displayName = "Program"
      }
    ]
    var bundle = WorkspaceV4Bundle(definition: definition, preferences: .init())
    for value in [Int32(-810), 201] {
      bundle.preferences.landscapeProgramPreferences[1, default: .init()].audioMasterVolumeDecibels
        .set(num: value, den: 10)
      #expect(
        WorkspaceBundleValidatorV4.validationIssues(in: bundle).contains {
          $0.error == .invalidMasterVolume
        })
    }
  }
  @Test("round trips independent canvas preferences through Protobuf")
  func canvasPreferencesRoundTrip() throws {
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    var landscape = Ldtx_Workspace_V4_ProgramPreferences()
    landscape.audioMasterVolumeDecibels = .with {
      $0.num = -16
      $0.den = 5
    }
    preferences.audioChannelGainsDecibels[2] = .with {
      $0.num = -61
      $0.den = 10
    }
    landscape.videoLayerHidden[3] = true
    var portrait = Ldtx_Workspace_V4_ProgramPreferences()
    portrait.audioMasterVolumeDecibels = .with {
      $0.num = 17
      $0.den = 10
    }
    portrait.audioChannelMuted[2] = true
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.scaleX = .with {
      $0.num = 1
      $0.den = 2
    }
    transform.scaleY = .with {
      $0.num = 1
      $0.den = 1
    }
    portrait.videoLayerTransforms[3] = transform
    preferences.landscapeProgramPreferences[1] = landscape
    preferences.portraitProgramPreferences[1] = portrait
    let decoded = try Ldtx_Workspace_V4_WorkspacePreferencesV4(
      serializedBytes: preferences.serializedData())
    #expect(decoded == preferences)
    #expect(
      decoded.audioChannelGainsDecibels[2]
        == Ldtx_Workspace_V4_Rational32.with {
          $0.num = -61
          $0.den = 10
        })
    #expect(decoded.landscapeProgramPreferences[1] == landscape)
    #expect(decoded.portraitProgramPreferences[1] == portrait)
  }

  @Test("rejects a Workspace gain referencing a missing audio input")
  func rejectsDanglingAudioGain() throws {
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.audioChannelGainsDecibels[99] = .with {
      $0.num = -6
      $0.den = 1
    }
    let workspace = WorkspaceV4Bundle(definition: .init(), preferences: preferences)
    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validate(workspace)
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains {
          $0.error == .missingAudioInputDevice(99)
        } == true
      })
  }

  @Test("rejects a Program that references a missing video layer")
  func rejectsMissingVideoLayer() {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 1
    program.displayName = "Main"
    definition.programs = [program]

    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validate(
          WorkspaceV4Bundle(
            definition: definition,
            preferences: .with {
              $0.landscapeProgramPreferences[1] = .with { $0.videoLayerInternalIds = [99] }
            }))
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains {
          $0.error == .missingVideoLayer(99)
        } == true
      })
  }

  @Test("allows an unassigned VFX Source")
  func allowsUnassignedVFXSource() throws {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.videoComponents = [
      .with {
        $0.vfxSource = .with {
          $0.internalID = 1
          $0.displayName = "Camera"
        }
      }
    ]
    try WorkspaceBundleValidatorV4.validate(definition)
  }

  @Test("PTS master must reference a VFX Source")
  func rejectsNonVFXTimingMaster() {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.videoComponents = [
      .with {
        $0.testPattern = .with {
          $0.internalID = 1
          $0.displayName = "Pattern"
        }
      }
    ]
    definition.canvasConfiguration.ptsMasterVfxSourceInternalID = 1
    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validate(definition)
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains {
          $0.error == .missingVfxSource(1)
        } == true
      })
  }

  @Test("OCR can reference a generated Video Component")
  func allowsGeneratedComponentForOCR() throws {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.videoComponents = [
      .with {
        $0.testPattern = .with {
          $0.internalID = 1
          $0.displayName = "Pattern"
        }
      }
    ]
    definition.visions = [
      .with {
        $0.ocrVision = .with {
          $0.internalID = 2
          $0.displayName = "OCR"
          $0.videoComponentInternalID = 1
        }
      }
    ]
    try WorkspaceBundleValidatorV4.validate(definition)
  }

  @Test("rejects entity IDs reused across resource kinds")
  func rejectsCrossKindDuplicateInternalID() {
    var input = Ldtx_Workspace_V4_VideoComponentWrapper()
    input.vfxSource = .with { $0.internalID = 1 }
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 1
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.videoComponents = [input]
    definition.programs = [program]

    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validate(definition)
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains {
          $0.error == .duplicateInternalID
        } == true
      })
  }

  @Test("rejects an OCR Vision without a video component")
  func rejectsVisionWithMissingVideoInput() {
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.internalID = 2
    vision.videoComponentInternalID = 1
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.ocrVision = vision
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.visions = [wrapper]

    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validate(definition)
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains {
          $0.error == .missingVideoComponent(1)
        } == true
      })
  }

  @Test("rejects dangling program preferences in both maps")
  func rejectsDanglingProgramPreferences() {
    for target in [
      \Ldtx_Workspace_V4_WorkspacePreferencesV4.landscapeProgramPreferences,
      \Ldtx_Workspace_V4_WorkspacePreferencesV4.portraitProgramPreferences,
    ] {
      var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
      preferences[keyPath: target][99] = .init()
      let workspace = WorkspaceV4Bundle(
        definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4(),
        preferences: preferences
      )

      #expect(
        performing: {
          try WorkspaceBundleValidatorV4.validate(workspace)
        },
        throws: {
          ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains {
            $0.error == .missingProgram(99)
          } == true
        })
    }
  }

  @Test("rejects an unsupported output profile")
  func rejectsUnsupportedOutputProfile() {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.canvasConfiguration.landscapeProfileID = "custom-4k"

    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validate(definition)
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains {
          $0.error == .unsupportedOutputProfile("custom-4k")
        } == true
      })
  }

  @Test("signed fixed-width IDs and reference keys round trip without loss")
  func signedIDsRoundTrip() throws {
    for id in [Int64.min, -1, 0, 1, Int64.max] {
      let program = Ldtx_Workspace_V4_ProgramDefinition.with { $0.internalID = id }
      let encoded = try program.serializedData()
      #expect(encoded.count == 9)
      #expect(try Ldtx_Workspace_V4_ProgramDefinition(serializedBytes: encoded).internalID == id)
      let preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4.with {
        $0.landscapeProgramPreferences[id] = .with {
          $0.videoLayerInternalIds = [id]
          $0.videoLayerHidden[id] = true
        }
      }
      #expect(
        try Ldtx_Workspace_V4_WorkspacePreferencesV4(
          serializedBytes: preferences.serializedData()) == preferences)
    }
  }

  @Test("negative and zero entity IDs cannot be persisted", arguments: [Int64.min, -1, 0])
  func rejectsNonpositiveID(_ id: Int64) {
    let definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
      $0.programs = [.with { $0.internalID = id }]
    }
    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validate(definition)
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains { $0.error == .invalidInternalID }
          == true
      })
  }

  @Test("negative references cannot be persisted")
  func rejectsNegativeReference() {
    let definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
      $0.programs = [
        .with {
          $0.internalID = 1
          $0.displayName = "Main"
        }
      ]
    }
    let preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4.with {
      $0.landscapeProgramPreferences[1] = .with { $0.videoLayerInternalIds = [-1] }
    }
    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validate(
          WorkspaceV4Bundle(
            definition: definition, preferences: preferences))
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains {
          $0.error == .missingVideoLayer(-1)
        } == true
      })
  }

  @Test("rejects an internal ID with the sign bit set")
  func rejectsInternalIDWithSignBit() {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = Int64.min
    definition.programs = [program]

    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validate(definition)
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains { $0.error == .invalidInternalID }
          == true
      })
  }

  @Test("rejects duplicate video layers in one Program")
  func rejectsDuplicateVideoLayers() {
    var video = Ldtx_Workspace_V4_VfxSourceComponent()
    video.internalID = 1
    video.displayName = "Camera"
    var input = Ldtx_Workspace_V4_VideoComponentWrapper()
    input.vfxSource = video
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 2
    program.displayName = "Main"
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.videoComponents = [input]
    definition.programs = [program]

    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validate(
          WorkspaceV4Bundle(
            definition: definition,
            preferences: .with {
              $0.landscapeProgramPreferences[2] = .with { $0.videoLayerInternalIds = [1, 1] }
            }))
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains {
          $0.error == .duplicateVideoLayer(2)
        } == true
      })
  }
  @Test("collects definition and preferences issues in both canvases")
  func collectsAllSaveIssues() {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.audioDevices = [
      .with {
        $0.internalID = 1
        $0.displayName = "Main"
      }
    ]
    definition.programs = [
      .with {
        $0.internalID = 2
        $0.displayName = "Main"
      }
    ]
    definition.videoComponents = [
      .with {
        $0.testPattern = .with {
          $0.internalID = 3
          $0.displayName = "Pattern"
        }
      }
    ]
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.audioChannelGainsDecibels[99] = .with {
      $0.num = 0
      $0.den = 1
    }
    preferences.landscapeProgramPreferences[2, default: .init()].videoLayerTransforms[3] = .with {
      $0.translationX = .with {
        $0.num = 11
        $0.den = 10
      }
    }
    preferences.portraitProgramPreferences[2, default: .init()].videoLayerTransforms[3] = .with {
      $0.bottomInset = .with {
        $0.num = -1
        $0.den = 1
      }
    }
    let issues = WorkspaceBundleValidatorV4.validationIssues(
      in: WorkspaceV4Bundle(definition: definition, preferences: preferences))
    #expect(issues.count == 5)
    #expect(
      issues.map { $0.error } == [
        .duplicateDisplayName("Main"), .duplicateDisplayName("Main"), .missingAudioInputDevice(99),
        .invalidBasicTransform, .invalidBasicTransform,
      ])
    #expect(issues[3].path.contains("Landscape"))
    #expect(issues[4].path.contains("Portrait"))
  }

  @Test("retained preferences reference existing components rather than membership")
  func allowsDetachedLayerPreferences() throws {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [
      .with {
        $0.internalID = 1
        $0.displayName = "Main"
      }
    ]
    definition.videoComponents = [
      .with {
        $0.testPattern = .with {
          $0.internalID = 2
          $0.displayName = "Pattern"
        }
      }
    ]
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.landscapeProgramPreferences[1, default: .init()].videoLayerHidden[2] = true
    preferences.portraitProgramPreferences[1, default: .init()].videoLayerTransforms[2] = .with {
      $0.translationX = .with {
        $0.num = 1
        $0.den = 2
      }
      $0.scaleX = .with {
        $0.num = 2
        $0.den = 1
      }
    }
    try WorkspaceBundleValidatorV4.validate(
      WorkspaceV4Bundle(definition: definition, preferences: preferences))
    definition.videoComponents = []
    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validate(
          WorkspaceV4Bundle(definition: definition, preferences: preferences))
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains {
          $0.error == .missingVideoLayer(2)
        } == true
      })
  }

  @Test("transform range validation preserves boundary and identity values")
  func validatesTransformRanges() throws {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [
      .with {
        $0.internalID = 1
        $0.displayName = "Main"
      }
    ]
    definition.videoComponents = [
      .with {
        $0.testPattern = .with {
          $0.internalID = 2
          $0.displayName = "Pattern"
        }
      }
    ]
    let cases: [(Ldtx_Workspace_V4_BasicTransform, Bool)] = [
      (.init(), true),
      (
        .with {
          $0.translationX = .with {
            $0.num = 1
            $0.den = 1
          }
          $0.translationY = .with {
            $0.num = 1
            $0.den = 1
          }
          $0.scaleX = .with {
            $0.num = 2
            $0.den = 1
          }
        }, true
      ),
      (
        .with {
          $0.translationX = .with {
            $0.num = 11
            $0.den = 10
          }
        }, false
      ),
      (
        .with {
          $0.translationY = .with {
            $0.num = -1
            $0.den = 10
          }
        }, false
      ),
      (
        .with {
          $0.scaleX = .with {
            $0.num = -1
            $0.den = 1
          }
        }, true
      ),
      (
        .with {
          $0.topInset = .with {
            $0.num = 11
            $0.den = 10
          }
        }, false
      ),
    ]
    for (transform, valid) in cases {
      var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
      preferences.landscapeProgramPreferences[1, default: .init()].videoLayerTransforms[2] =
        transform
      let workspace = WorkspaceV4Bundle(definition: definition, preferences: preferences)
      if valid {
        try WorkspaceBundleValidatorV4.validate(workspace)
      } else {
        #expect(
          performing: {
            try WorkspaceBundleValidatorV4.validate(workspace)
          },
          throws: {
            ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains {
              $0.error == .invalidBasicTransform
            } == true
          })
      }
    }
  }

  @Test("extended sRGB allows RGB outside the unit interval but constrains alpha")
  func validatesExtendedSRGBComponents() throws {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
      $0.videoComponents = [
        .with {
          $0.solidColorFill = .with {
            $0.internalID = 1
            $0.displayName = "Fill"
            $0.extendedSrgbColor = .with {
              $0.red = -0.25
              $0.green = 1.5
              $0.blue = 0
              $0.alpha = 0.8
            }
          }
        }
      ]
    }
    let bytes = try definition.serializedData()
    try WorkspaceBundleValidatorV4.validate(definition)
    #expect(try definition.serializedData() == bytes)
    definition.videoComponents[0].solidColorFill.extendedSrgbColor.alpha = 1.5
    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validate(definition)
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains { $0.error == .invalidColor }
          == true
      })
  }

}
