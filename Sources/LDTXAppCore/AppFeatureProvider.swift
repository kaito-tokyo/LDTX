// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXCapture
import LDTXInternalProtocols
import LDTXProgramRuntime
import LDTXTaskQueue
import LDTXWorkspace
import LDTXYouTubeAuth
import SwiftUI

public struct AppConfiguration: Sendable, Equatable {
  public struct UIFeatures: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let vision = UIFeatures(rawValue: 1 << 0)
    public static let backgroundSegmentation = UIFeatures(rawValue: 1 << 1)
  }
  public var bundleIdentifier: String
  public var youtubeOAuthKeychainService: String
  public var mcpServerName: String
  public var xpcServiceName: String
  public var uiFeatures: UIFeatures
  public init(
    bundleIdentifier: String, youtubeOAuthKeychainService: String, mcpServerName: String,
    xpcServiceName: String, uiFeatures: UIFeatures
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.youtubeOAuthKeychainService = youtubeOAuthKeychainService
    self.mcpServerName = mcpServerName
    self.xpcServiceName = xpcServiceName
    self.uiFeatures = uiFeatures
  }
}

@MainActor
public protocol WorkspaceVisionFeatureProviding: AnyObject {
  init(workspaceResourceQueue: WorkspaceResourceQueue)
  var presenter: any VisionRuntimePresenting { get }
  func synchronize(visions: [WorkspaceVisionDefinition], context: WorkspaceVisionFeatureContext)
  func stop(completion: @escaping @MainActor @Sendable () -> Void)
  func stopAnalysis(completion: @escaping @MainActor @Sendable () -> Void)
  func submit(
    _ vision: WorkspaceVisionDefinition,
    source: BackgroundTaskSubmission,
    context: WorkspaceVisionFeatureContext
  )
  func perform(
    _ vision: WorkspaceVisionDefinition,
    stopToken: StopToken,
    context: WorkspaceVisionFeatureContext,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  )
}

@MainActor
public protocol WorkspaceV4VisionFeatureProviding: AnyObject {
  func synchronize(
    visions: [Ldtx_Workspace_V4_VisionWrapper],
    context: WorkspaceV4VisionFeatureContext
  )
  func stop()
}

extension WorkspaceVisionFeatureProviding {
  func stop(completion: @escaping @MainActor @Sendable () -> Void = {}) {
    stop(completion: completion)
  }

  func stopAnalysis(completion: @escaping @MainActor @Sendable () -> Void = {}) {
    stopAnalysis(completion: completion)
  }
}

@MainActor
public protocol AppFeatureProvider {
  var configuration: AppConfiguration { get }
  var workspaceFeatureAvailability: WorkspaceFeatureAvailability { get }
  var backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? { get }
  func makeYouTubeClientService() -> YouTubeClientService
  func makeProgramRuntime(
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    programPreferencesState: ProgramPreferencesState,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  ) -> ProgramRuntime
  func makeVisionFeature(workspaceResourceQueue: WorkspaceResourceQueue)
    -> any WorkspaceVisionFeatureProviding
  func makeV4VisionFeature() -> any WorkspaceV4VisionFeatureProviding
}

@MainActor
public enum AppFeatureRegistry {
  public static var provider: any AppFeatureProvider = UnconfiguredAppFeatureProvider()
}

@MainActor
private final class UnconfiguredAppFeatureProvider: AppFeatureProvider {
  var configuration: AppConfiguration { fatalError("LDTX features were not configured.") }
  var workspaceFeatureAvailability: WorkspaceFeatureAvailability {
    fatalError("LDTX features were not configured.")
  }
  var backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? {
    fatalError("LDTX features were not configured.")
  }

  func makeYouTubeClientService() -> YouTubeClientService {
    fatalError("LDTX features were not configured.")
  }

  func makeProgramRuntime(
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    programPreferencesState: ProgramPreferencesState,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  ) -> ProgramRuntime {
    fatalError("LDTX features were not configured.")
  }

  func makeVisionFeature(workspaceResourceQueue: WorkspaceResourceQueue)
    -> any WorkspaceVisionFeatureProviding
  {
    fatalError("LDTX features were not configured.")
  }

  func makeV4VisionFeature() -> any WorkspaceV4VisionFeatureProviding {
    fatalError("LDTX features were not configured.")
  }
}
