//
//  CustomDirScanner.swift
//  AppPorts
//
//  Created by Codex on 2026/6/26.
//

import Foundation

actor CustomDirScanner {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    private(set) var sizeCacheUpdatedAt: Date?

    func scan(configs: [CustomDirConfig], calculateSizes: Bool = false,
              forceSizeRefresh: Bool = false) -> [CustomDirPair] {
        let cache = ToolDirectorySizeCacheStore.customDirectories
        var snapshot = calculateSizes ? cache.load() : .init()
        let originalEntries = snapshot.entries
        var result: [CustomDirPair] = []
        for config in configs {
            guard !Task.isCancelled else { return [] }
            var pair = scan(config: config, calculateSizes: false)
            if calculateSizes {
                applyCachedSize(to: &pair.local, snapshot: &snapshot, forceRefresh: forceSizeRefresh)
                applyCachedSize(to: &pair.external, snapshot: &snapshot, forceRefresh: forceSizeRefresh)
            }
            result.append(pair)
        }
        guard !Task.isCancelled else { return [] }
        if calculateSizes {
            let keys = Set(result.flatMap { [$0.local.id, $0.external.id] })
            snapshot.entries = snapshot.entries.filter { keys.contains($0.key) }
            if snapshot.entries != originalEntries { cache.save(snapshot) }
            sizeCacheUpdatedAt = snapshot.updatedAt
        }
        return result
    }

    private func applyCachedSize(to entry: inout CustomDirEntry,
                                 snapshot: inout ToolDirectorySizeCacheStore.Snapshot,
                                 forceRefresh: Bool) {
        guard !Task.isCancelled, fileManager.fileExists(atPath: entry.url.path),
              let identity = ToolDirectorySizeCacheStore.identity(for: entry.dataDirItem) else {
            snapshot.entries.removeValue(forKey: entry.id)
            return
        }
        if !forceRefresh, let cached = snapshot.entries[entry.id], cached.identity == identity {
            entry.sizeBytes = cached.bytes
            entry.size = LocalizedByteCountFormatter.string(fromByteCount: cached.bytes)
            return
        }
        snapshot.entries.removeValue(forKey: entry.id)
        guard applySize(to: &entry), !Task.isCancelled,
              identity == ToolDirectorySizeCacheStore.identity(for: entry.dataDirItem) else { return }
        snapshot.entries[entry.id] = .init(identity: identity, sourcePath: entry.url.standardizedFileURL.path,
            targetPath: entry.url.resolvingSymlinksInPath().standardizedFileURL.path,
            bytes: entry.sizeBytes, measuredAt: Date())
    }

    private func scan(config: CustomDirConfig, calculateSizes: Bool) -> CustomDirPair {
        let localURL = config.localURL
        let externalURL = config.externalDestinationURL
        let localState = inspectLocal(localURL: localURL, expectedExternalURL: externalURL)
        let externalExists = fileManager.fileExists(atPath: externalURL.path)
        let externalStatus: String

        if externalExists {
            externalStatus = localState.status == CustomDirStatus.linked
                ? CustomDirStatus.linked
                : CustomDirStatus.pendingRelink
        } else {
            externalStatus = CustomDirStatus.missing
        }

        var localEntry = CustomDirEntry(
            config: config,
            kind: .local,
            url: localURL,
            status: localState.status,
            linkedDestination: localState.linkedDestination
        )
        var externalEntry = CustomDirEntry(
            config: config,
            kind: .external,
            url: externalURL,
            status: externalStatus,
            linkedDestination: localState.status == CustomDirStatus.linked ? localURL : nil
        )

        if calculateSizes {
            applySize(to: &localEntry)
            applySize(to: &externalEntry)
        }

        return CustomDirPair(config: config, local: localEntry, external: externalEntry)
    }

    private func inspectLocal(localURL: URL, expectedExternalURL: URL) -> (status: String, linkedDestination: URL?) {
        if isSymbolicLink(at: localURL) {
            guard let destination = resolveSymlinkDestination(of: localURL) else {
                return (CustomDirStatus.orphanedLink, nil)
            }

            if fileManager.fileExists(atPath: destination.path) {
                let status = destination.standardizedFileURL == expectedExternalURL.standardizedFileURL
                    ? CustomDirStatus.linked
                    : CustomDirStatus.destinationConflict
                return (status, destination.standardizedFileURL)
            }

            return (CustomDirStatus.orphanedLink, destination.standardizedFileURL)
        }

        if fileManager.fileExists(atPath: localURL.path) {
            return (CustomDirStatus.local, nil)
        }

        return (CustomDirStatus.missing, nil)
    }

    @discardableResult
    private func applySize(to entry: inout CustomDirEntry) -> Bool {
        guard fileManager.fileExists(atPath: entry.url.path) else { return false }
        // Our persistent cache controls reuse. A manual refresh must bypass
        // the shared in-memory directory-size cache as well.
        let measured = measureDirectorySize(at: entry.url, fileManager: fileManager, useCache: false)
        entry.sizeBytes = measured.bytes
        entry.size = LocalizedByteCountFormatter.string(fromByteCount: measured.bytes)
        if !measured.readIssues.isEmpty { entry.size? += "（统计不完整）".localized }
        return measured.readIssues.isEmpty
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let fileType = attrs[.type] as? FileAttributeType else {
            return false
        }
        return fileType == .typeSymbolicLink
    }

    private func resolveSymlinkDestination(of url: URL) -> URL? {
        guard let destinationPath = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }

        if destinationPath.hasPrefix("/") {
            return URL(fileURLWithPath: destinationPath).standardizedFileURL
        }

        return url
            .deletingLastPathComponent()
            .appendingPathComponent(destinationPath)
            .standardizedFileURL
    }
}
