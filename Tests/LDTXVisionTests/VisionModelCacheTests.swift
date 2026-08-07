// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing
@testable import LDTXVision
import LDTXWorkspace

@Suite("Vision model cache")
struct VisionModelCacheTests {
    @Test("Resolves a complete snapshot from HF_HUB_CACHE")
    func resolvesStandardCacheSnapshot() throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        try fixture.installSnapshot()

        let result = VisionModelCache.snapshotDirectory(
            for: WorkspaceVisionModel(repositoryID: "mlx-community/Qwen3-VL-2B-Instruct-4bit"),
            environment: ["HF_HUB_CACHE": fixture.root.path],
            homeDirectory: fixture.root
        )

        #expect(result == fixture.snapshot)
    }

    @Test("Does not accept a partial download")
    func rejectsPartialSnapshot() throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        try fixture.installSnapshot(includeWeights: false)

        let result = VisionModelCache.snapshotDirectory(
            for: WorkspaceVisionModel(repositoryID: "mlx-community/Qwen3-VL-2B-Instruct-4bit"),
            environment: ["HF_HUB_CACHE": fixture.root.path],
            homeDirectory: fixture.root
        )

        #expect(result == nil)
    }

    @Test("Rejects a weight whose digest does not match the pinned model")
    func rejectsUnexpectedWeightDigest() throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        try fixture.installSnapshot()

        let model = WorkspaceVisionModel(
            repositoryID: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            expectedWeightSHA256: [
                "model.safetensors": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
            ]
        )
        let result = VisionModelCache.snapshotDirectory(
            for: model,
            environment: ["HF_HUB_CACHE": fixture.root.path],
            homeDirectory: fixture.root
        )

        #expect(result == nil)
    }

    @Test("Uses HF_HOME/hub when HF_HUB_CACHE is absent")
    func resolvesHFHome() {
        let root = URL(fileURLWithPath: "/tmp/huggingface-test", isDirectory: true)
        #expect(
            VisionModelCache.hubCacheDirectory(
                environment: ["HF_HOME": root.path],
                homeDirectory: URL(fileURLWithPath: "/unused")
            ) == root.appendingPathComponent("hub", isDirectory: true)
        )
    }

    @Test("Requires digests for every indexed weight shard")
    func rejectsUnpinnedIndexedWeightShard() throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let weights = [
            "model-00001-of-00002.safetensors": Data("first".utf8),
            "model-00002-of-00002.safetensors": Data("second".utf8),
        ]
        try fixture.installIndexedSnapshot(weights: weights)
        let model = WorkspaceVisionModel(
            repositoryID: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            expectedWeightSHA256: [
                "model-00001-of-00002.safetensors": Self.sha256(
                    try #require(weights["model-00001-of-00002.safetensors"])
                )
            ]
        )

        #expect(VisionModelCache.snapshotDirectory(
            for: model,
            environment: ["HF_HUB_CACHE": fixture.root.path],
            homeDirectory: fixture.root
        ) == nil)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CacheFixture {
    static let commit = String(repeating: "a", count: 40)

    let root: URL
    let repository: URL
    let snapshot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        repository = root.appendingPathComponent(
            "models--mlx-community--Qwen3-VL-2B-Instruct-4bit",
            isDirectory: true
        )
        snapshot = repository
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(Self.commit, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    }

    func installSnapshot(includeWeights: Bool = true) throws {
        let refs = repository.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data(Self.commit.utf8).write(to: refs.appendingPathComponent("main"))
        for name in ["config.json", "tokenizer.json", "preprocessor_config.json"] {
            try Data("{}".utf8).write(to: snapshot.appendingPathComponent(name))
        }
        if includeWeights {
            try Data().write(to: snapshot.appendingPathComponent("model.safetensors"))
        }
    }

    func installIndexedSnapshot(weights: [String: Data]) throws {
        try installSnapshot(includeWeights: false)
        for (name, data) in weights {
            try data.write(to: snapshot.appendingPathComponent(name))
        }
        let weightMap = Dictionary(uniqueKeysWithValues: weights.keys.enumerated().map {
            ("weight.\($0.offset)", $0.element)
        })
        let index = try JSONSerialization.data(withJSONObject: ["weight_map": weightMap])
        try index.write(to: snapshot.appendingPathComponent("model.safetensors.index.json"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
