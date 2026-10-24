// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletModel
import Testing

@Suite(.tags(.easy))
struct WorkspaceTransactionalCommandUnitTestSuite {
  @Test("LUB-1027: Output active permissions and starting stop match the confirmed contract")
  func outputActivePermissionsAndStartingStopMatchTheConfirmedContract() {
    #expect(
      WorkspaceTransactionalCommand.allCases.map(\.isAllowedDuringOutput) == [
        false, false, true, false, true, false,
      ])
    #expect(WorkspaceRecordingState.starting.canStop)
    #expect(!WorkspaceRecordingState.starting.canStart)
  }
  @Test("LUB-1027: Normal batch produces one error retaining every command and close guidance")
  func normalBatchProducesOneErrorRetainingEveryCommandAndCloseGuidance() {
    let notifications = WorkspaceCommandFailureNotification.stalledCommands([
      .reconstructRuntime, .switchProgram, .stopOutputSession, .closeWorkspace,
    ])
    let cause = NSError(
      domain: "batch-test", code: 92,
      userInfo: [NSLocalizedDescriptionKey: "Original failure."])
    let error = WorkspaceCommandFailureNotification.aggregatedError(notifications, causedBy: cause)
    #expect(error?.localizedDescription == "Workspace operations could not be completed.")
    #expect(error?.localizedFailureReason?.contains("saved Workspace") == true)
    #expect(error?.localizedFailureReason?.contains("Program") == true)
    #expect(error?.localizedFailureReason?.contains("closed") == true)
    #expect(error?.localizedFailureReason?.contains("Original failure.") == true)
    #expect(error?.localizedRecoverySuggestion?.contains("Force Quit") == true)
    #expect(error?.localizedRecoverySuggestion?.contains("may still be running") == true)
  }
  @Test("LUB-1027: Recovery guidance retains cause and never claims stop succeeded")
  func recoveryGuidanceRetainsCauseAndNeverClaimsStopSucceeded() {
    let cause = NSError(
      domain: "test", code: 73,
      userInfo: [
        NSLocalizedDescriptionKey: "An actionable cause.",
        NSLocalizedRecoverySuggestionErrorKey: "Check the underlying resource.",
      ])
    for notification in WorkspaceCommandFailureNotification.stalledCommands([.closeWorkspace]) {
      let error = notification.error(causedBy: cause)
      #expect(error.code == 73)
      #expect(error.localizedFailureReason?.contains("An actionable cause.") == true)
      #expect(error.localizedRecoverySuggestion?.contains("Force Quit") == true)
      #expect(error.localizedRecoverySuggestion?.contains("Check the underlying resource.") == true)
      #expect(error.localizedRecoverySuggestion?.contains("unsaved edits and recordings") == true)
    }
    let stop = WorkspaceCommandFailureNotification.stalledCommands([.stopOutputSession])[0]
      .error(causedBy: cause)
    #expect(stop.localizedDescription == "Output could not be stopped.")
    #expect(stop.localizedRecoverySuggestion?.contains("may still be running") == true)
  }
  @Test("LUB-1027: Stop and close keep their guidance without suppressing other commands")
  func stopAndCloseKeepTheirGuidanceWithoutSuppressingOtherCommands() {
    let commands = WorkspaceTransactionalCommand.allCases
    let notifications = WorkspaceCommandFailureNotification.stalledCommands(commands)
    #expect(notifications.map(\.command) == commands)
    #expect(
      notifications.map(\.dialog) == [
        .commandError, .commandError, .commandError, .commandError, .stopFailed, .closeFailed,
      ])
    #expect(
      commands.filter(\.requiresConsistencyRepair) == [
        .reconstructRuntime, .updateDeviceAssignment, .switchProgram,
      ])
  }

}
