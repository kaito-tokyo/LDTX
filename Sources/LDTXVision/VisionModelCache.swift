// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspace

/// Resolves models already installed in the standard Hugging Face Hub cache.
/// This type deliberately performs no network access.
enum VisionModelCache {
    static func snapshotDirectory(
        for model: WorkspaceVisionModel,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let repositoryDirectoryName = repositoryDirectoryName(for: model.repositoryID) else {
            return nil
        }
        let cache = hubCacheDirectory(environment: environment, homeDirectory: homeDirectory)
        let repository = cache.appendingPathComponent(repositoryDirectoryName, isDirectory: true)
        let revision = model.revision ?? "main"
        let commit: String
        if isCommitHash(revision) {
            commit = revision
        } else {
            let reference = repository
                .appendingPathComponent("refs", isDirectory: true)
                .appendingPathComponent(revision)
            guard let contents = try? String(contentsOf: reference, encoding: .utf8) else {
                return nil
            }
            commit = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commit.isEmpty else { return nil }
        }
        let snapshot = repository
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(commit, isDirectory: true)
        return isCompleteSnapshot(snapshot, fileManager: fileManager) ? snapshot : nil
    }

    static func hubCacheDirectory(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        if let path = environment["HF_HUB_CACHE"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let path = environment["HF_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
    }

    private static func repositoryDirectoryName(for id: String) -> String? {
        let components = id.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components.allSatisfy({ !$0.isEmpty }) else { return nil }
        return "models--\(components[0])--\(components[1])"
    }

    private static func isCommitHash(_ revision: String) -> Bool {
        revision.count == 40 && revision.allSatisfy(\.isHexDigit)
    }

    private static func isCompleteSnapshot(_ directory: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            fileManager.fileExists(atPath: directory.appendingPathComponent("config.json").path),
            fileManager.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path),
            fileManager.fileExists(
                atPath: directory.appendingPathComponent("preprocessor_config.json").path
            )
        else { return false }

        let index = directory.appendingPathComponent("model.safetensors.index.json")
        if fileManager.fileExists(atPath: index.path) {
            guard let data = try? Data(contentsOf: index),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let weightMap = object["weight_map"] as? [String: String]
            else { return false }
            return !weightMap.isEmpty && Set(weightMap.values).allSatisfy {
                fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
        }
        return fileManager.fileExists(
            atPath: directory.appendingPathComponent("model.safetensors").path
        )
    }
}
