// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXYouTube
import SwiftUI

enum ContentSettingsPlacement {
  case content
  case detail
  case modal
}

struct ContentSettingsForm: View {
  @Bindable var outputDestination: OutputDestinationModel
  var existingBroadcasts: [YouTubeLiveBroadcast]
  var isLoadingBroadcasts: Bool
  var isConnectingBroadcast: Bool
  var isStreamingToYouTube: Bool
  var isRecording: Bool
  var canSelectYouTubeBroadcast: Bool
  var localOutputStatus: String
  var refreshExistingBroadcasts: () -> Void
  var manageYouTubeBroadcasts: () -> Void
  var chooseLocalOutputDirectory: () -> Void
  var placement: ContentSettingsPlacement = .content
  @State private var isShowingBroadcastChooser = false

  var body: some View {
    Group {
      switch placement {
      case .content:
        outputSection
      case .detail:
        outputDetailSections
      case .modal:
        outputSection
        outputDetailSections
      }
    }
  }

  private var youtubeBroadcastSection: some View {
    Section("YouTube Broadcast") {
      selectedBroadcastRows

      HStack(alignment: .center, spacing: 8) {
        actionButton(
          title: "Manage",
          systemImage: "slider.horizontal.3",
          action: manageYouTubeBroadcasts
        )
        .buttonStyle(.bordered)

        actionButton(
          title: isLoadingBroadcasts ? "Loading" : "Select",
          systemImage: isLoadingBroadcasts ? "hourglass" : "dot.radiowaves.left.and.right",
          action: showBroadcastChooser
        )
        .buttonStyle(.bordered)
        .disabled(!canSelectYouTubeBroadcast)
      }
    }
    .sheet(isPresented: $isShowingBroadcastChooser) {
      broadcastChooser
    }
  }

  @ViewBuilder
  private var outputDetailSections: some View {
    if outputDestination.isYouTubeEnabled {
      youtubeBroadcastSection
    }
    if outputDestination.isRecordingEnabled {
      recordingSection
    }
  }

  private var outputSection: some View {
    Section("Outputs") {
      Toggle("Record", isOn: $outputDestination.isRecordingEnabled)
      Toggle("YouTube", isOn: $outputDestination.isYouTubeEnabled)
    }
  }

  private var recordingSection: some View {
    Section("Recording") {
      HStack {
        LabeledContent("Output Folder") {
          Text(localOutputStatus)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }

        Button {
          chooseLocalOutputDirectory()
        } label: {
          Label("Choose", systemImage: "folder")
        }
      }
    }
  }

  @ViewBuilder
  private var selectedBroadcastRows: some View {
    if let selectedBroadcast {
      LabeledContent("Title") {
        Text(selectedBroadcast.snippet?.title ?? "Untitled")
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      LabeledContent("ID") {
        Text(selectedBroadcast.id ?? "Unavailable")
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
      }
    } else if let selectedBroadcastID = outputDestination.selectedExistingBroadcastID,
      !selectedBroadcastID.isEmpty
    {
      LabeledContent("Title") {
        Text("Unavailable")
          .foregroundStyle(.secondary)
      }

      LabeledContent("ID") {
        Text(selectedBroadcastID)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
      }
    } else {
      LabeledContent("Title") {
        Text("Not selected")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var selectedBroadcast: YouTubeLiveBroadcast? {
    guard let selectedExistingBroadcastID = outputDestination.selectedExistingBroadcastID else {
      return nil
    }
    return existingBroadcasts.first { $0.id == selectedExistingBroadcastID }
  }

  private var broadcastChooser: some View {
    NavigationStack {
      Group {
        if isLoadingBroadcasts && existingBroadcasts.isEmpty {
          ContentUnavailableView {
            Label("Loading broadcasts", systemImage: "hourglass")
          } description: {
            Text("Looking for active and upcoming YouTube LiveBroadcasts.")
          }
        } else if existingBroadcasts.isEmpty {
          ContentUnavailableView {
            Label("No LiveBroadcasts", systemImage: "dot.radiowaves.left.and.right")
          } description: {
            Text("Create or schedule an active or upcoming broadcast in Manage.")
          }
        } else {
          List(existingBroadcasts, id: \.id) { broadcast in
            Button {
              outputDestination.selectedExistingBroadcastID = broadcast.id
              isShowingBroadcastChooser = false
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(broadcast.snippet?.title ?? "Untitled")
                  .foregroundStyle(.primary)
                Text(broadcast.id ?? "Unavailable")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if let status = broadcastStatusLabel(broadcast) {
                  Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
          }
        }
      }
      .navigationTitle("Select LiveBroadcast")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            isShowingBroadcastChooser = false
          }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Refresh") {
            refreshExistingBroadcasts()
          }
          .disabled(isLoadingBroadcasts)
        }
      }
    }
    .frame(minWidth: 440, minHeight: 320)
  }

  private func actionButton(
    title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 8) {
        Image(systemName: systemImage)
        Text(title)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func showBroadcastChooser() {
    isShowingBroadcastChooser = true
    refreshExistingBroadcasts()
  }

  private func broadcastStatusLabel(_ broadcast: YouTubeLiveBroadcast) -> String? {
    if let lifeCycleStatus = broadcast.status?.lifeCycleStatus, !lifeCycleStatus.isEmpty {
      return lifeCycleStatus.capitalized
    }
    if broadcast.snippet?.actualStartTime != nil {
      return "Active"
    }
    if broadcast.snippet?.scheduledStartTime != nil {
      return "Upcoming"
    }
    return nil
  }
}

#if DEBUG
  #Preview("Content Settings Form") {
    ContentSettingsFormPreviewHost()
      .frame(width: 560, height: 760)
  }

  private struct ContentSettingsFormPreviewHost: View {
    @State private var outputDestination = LDTXAppUIPreviewFixtures.makeOutputDestinationModel()

    var body: some View {
      Form {
        ContentSettingsForm(
          outputDestination: outputDestination,
          existingBroadcasts: LDTXAppUIPreviewFixtures.existingBroadcasts,
          isLoadingBroadcasts: false,
          isConnectingBroadcast: false,
          isStreamingToYouTube: false,
          isRecording: false,
          canSelectYouTubeBroadcast: true,
          localOutputStatus: LDTXAppUIPreviewFixtures.localOutputStatus,
          refreshExistingBroadcasts: {},
          manageYouTubeBroadcasts: {},
          chooseLocalOutputDirectory: {},
          placement: .modal
        )
      }
      .formStyle(.grouped)
    }
  }
#endif
