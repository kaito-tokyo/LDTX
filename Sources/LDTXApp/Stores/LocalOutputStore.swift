// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct LocalOutputStore {
    private var securityScopedURL: URL?
    private var isAccessingSecurityScopedResource = false
    private let service: any LocalOutputService

    init(service: any LocalOutputService) {
        self.service = service
    }

    var defaultBaseDirectory: URL { service.defaultBaseDirectory }

    mutating func beginAccess(to directory: URL) {
        endAccess()
        isAccessingSecurityScopedResource = directory.startAccessingSecurityScopedResource()
        securityScopedURL = directory
    }

    mutating func endAccess() {
        if isAccessingSecurityScopedResource {
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }
        securityScopedURL = nil
        isAccessingSecurityScopedResource = false
    }

    func makeMP4OutputURL(baseDirectory: URL) -> URL {
        service.makeMP4OutputURL(baseDirectory: baseDirectory)
    }

    func makeDASHOutputDirectory(baseDirectory: URL) -> URL {
        service.makeDASHOutputDirectory(baseDirectory: baseDirectory)
    }

    func prepareMP4OutputDirectory(for outputURL: URL) throws {
        try service.prepareMP4OutputDirectory(for: outputURL)
    }

    func validateWritableBaseDirectory(_ directory: URL) throws {
        try service.validateWritableBaseDirectory(directory)
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
