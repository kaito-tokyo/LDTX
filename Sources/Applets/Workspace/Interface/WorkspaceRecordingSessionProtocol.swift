// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

@MainActor
public protocol WorkspaceRecordingSessionProtocol: AnyObject, Observable {
  var state: WorkspaceRecordingState { get set }
  var isRecording: Bool { get }
  var isLocalRecording: Bool { get }
  var screenshotsDirectory: URL? { get }
  func start() async
  func stop() async
  func updateMixPreferences()
  func captureScreenshots() throws -> [URL]
}
