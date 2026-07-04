// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct LocalOutputStore {
    private(set) var selectedBaseDirectory: URL?

    private var securityScopedURL: URL?
    private var isAccessingSecurityScopedResource = false
    private let service: any LocalOutputService

    init(service: any LocalOutputService) {
        self.service = service
    }

    var baseDirectory: URL {
        selectedBaseDirectory ?? service.defaultBaseDirectory
    }

    var status: String {
        baseDirectory.path
    }

    mutating func selectBaseDirectory(_ url: URL) {
        selectedBaseDirectory = url
    }

    mutating func beginAccess() {
        endAccess()
        guard let selectedBaseDirectory else { return }
        isAccessingSecurityScopedResource = selectedBaseDirectory.startAccessingSecurityScopedResource()
        securityScopedURL = selectedBaseDirectory
    }

    mutating func endAccess() {
        if isAccessingSecurityScopedResource {
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }
        securityScopedURL = nil
        isAccessingSecurityScopedResource = false
    }

    func makeMP4OutputURL() -> URL {
        service.makeMP4OutputURL(baseDirectory: baseDirectory)
    }

    func makeDASHOutputDirectory() -> URL {
        service.makeDASHOutputDirectory(baseDirectory: baseDirectory)
    }

    func prepareMP4OutputDirectory(for outputURL: URL) throws {
        try service.prepareMP4OutputDirectory(for: outputURL)
    }

    func prepareDASHOutputDirectory(
        _ outputDirectory: URL,
        targetWidth: Int,
        targetHeight: Int,
        frameRate: Int,
        videoBitRate: Int
    ) throws {
        try service.prepareDASHOutputDirectory(
            outputDirectory,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            frameRate: frameRate,
            videoBitRate: videoBitRate
        )
    }
}
