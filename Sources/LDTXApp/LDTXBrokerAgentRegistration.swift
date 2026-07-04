// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAutomation
import OSLog
import ServiceManagement

private let ldtxBrokerAgentLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "BrokerAgent"
)

enum LDTXBrokerAgentRegistration {
    static func registerIfNeeded() -> Bool {
        let bundleLayout = logBrokerAgentBundleLayout()

        let service = SMAppService.agent(
            plistName: LDTXAutomationService.launchAgentPlistName
        )

        switch service.status {
        case .enabled:
            return true
        case .notRegistered:
            return register(service)
        case .requiresApproval:
            ldtxBrokerAgentLogger.warning("Broker LaunchAgent requires user approval")
            return false
        case .notFound:
            ldtxBrokerAgentLogger.error("Broker LaunchAgent service status is notFound")
            guard bundleLayout.plistExists, bundleLayout.helperExists else {
                return false
            }

            ldtxBrokerAgentLogger.info(
                "Broker LaunchAgent files exist despite notFound status; attempting registration"
            )
            return register(service)
        @unknown default:
            ldtxBrokerAgentLogger.error("Broker LaunchAgent status is unknown")
            return false
        }
    }
}

private struct BrokerAgentBundleLayout {
    var plistExists: Bool
    var helperExists: Bool
}

private func register(_ service: SMAppService) -> Bool {
    do {
        try service.register()
        ldtxBrokerAgentLogger.info("Registered LDTX broker LaunchAgent")
        return true
    } catch {
        let nsError = error as NSError
        ldtxBrokerAgentLogger.error(
            """
            Broker LaunchAgent registration failed \
            errorDomain=\(nsError.domain, privacy: .public) \
            errorCode=\(nsError.code, privacy: .public) \
            description=\(nsError.localizedDescription, privacy: .public)
            """
        )
        return false
    }
}

private func logBrokerAgentBundleLayout() -> BrokerAgentBundleLayout {
    let bundleURL = Bundle.main.bundleURL
    let plistURL = bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("Library")
        .appendingPathComponent("LaunchAgents")
        .appendingPathComponent(LDTXAutomationService.launchAgentPlistName)
    let helperURL = bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("Library")
        .appendingPathComponent("Helpers")
        .appendingPathComponent("LDTXBrokerService")
    let fileManager = FileManager.default
    let layout = BrokerAgentBundleLayout(
        plistExists: fileManager.fileExists(atPath: plistURL.path),
        helperExists: fileManager.fileExists(atPath: helperURL.path)
    )

    ldtxBrokerAgentLogger.info(
        """
        Broker LaunchAgent lookup \
        bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "(nil)", privacy: .public) \
        bundleURL=\(bundleURL.path, privacy: .public) \
        plistURL=\(plistURL.path, privacy: .public) \
        plistExists=\(layout.plistExists, privacy: .public) \
        helperURL=\(helperURL.path, privacy: .public) \
        helperExists=\(layout.helperExists, privacy: .public)
        """
    )
    return layout
}
