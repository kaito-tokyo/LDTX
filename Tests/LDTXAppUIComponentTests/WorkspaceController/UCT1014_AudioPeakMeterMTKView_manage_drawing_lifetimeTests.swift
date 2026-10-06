// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import Observation
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1014: manage-drawing-lifetime", .serialized)
  @MainActor
  struct UCT1014AudioPeakMeterMTKViewIntegrationTestSuite {
    private static var controller: NSDocumentController {
      UIComponentTestEnvironment.documentController
    }
    init() { _ = Self.controller }

    @Test(
      "UCT-1014.1: Drawing follows Window attachment and UI releases without external stop calls")
    func meterOwnsDrawingLifetimeAndEditorsReleaseWithoutStop() async throws {
      _ = NSApplication.shared
      let first = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
        backing: .buffered, defer: false)
      let second = NSWindow(
        contentRect: first.frame, styleMask: [.titled], backing: .buffered, defer: false)
      first.isReleasedWhenClosed = false
      second.isReleasedWhenClosed = false
      defer {
        first.close()
        second.close()
      }
      var meter: AudioPeakMeterMTKView? = AudioPeakMeterMTKView()
      weak var releasedMeter = meter
      #expect(try #require(meter).isPaused)
      first.contentView?.addSubview(try #require(meter))
      #expect(meter?.isPaused == (meter?.device == nil))
      first.close()
      #expect(meter?.isPaused == true)
      meter?.removeFromSuperview()
      second.contentView?.addSubview(try #require(meter))
      #expect(meter?.isPaused == (meter?.device == nil))
      meter?.removeFromSuperview()
      #expect(meter?.isPaused == true)
      meter = nil
      for _ in 0..<100 {
        if releasedMeter == nil { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(releasedMeter == nil)

      let service = WorkspaceStoreService(definition: .init(), preferences: .init())
      var audio: AudioMixEditor? = AudioMixEditor(storeService: service)
      var master: MasterVolumeEditor? = MasterVolumeEditor(storeService: service)
      var layers: VideoLayersEditor? = VideoLayersEditor(storeService: service, target: .landscape)
      weak var releasedAudio = audio
      weak var releasedMaster = master
      weak var releasedLayers = layers
      _ = audio?.view
      _ = master?.view
      _ = layers?.view
      audio = nil
      master = nil
      layers = nil
      #expect(releasedAudio == nil)
      #expect(releasedMaster == nil)
      #expect(releasedLayers == nil)
    }

  }
}
