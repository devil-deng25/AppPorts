import Darwin
import Foundation

/// Phase measurements for one operation. Do not cache content by timestamps:
/// MAP_SHARED writes can change readable bytes before mtime/ctime changes.
final class DataTransferSession: @unchecked Sendable {
    enum Phase: String, CaseIterable { case preparation, scan, copy, verification, switching, cleanup }
    @TaskLocal static var current: DataTransferSession?
    @TaskLocal static var progress: DataTransferProgress?
    @TaskLocal private static var phase: Phase?

    let volumePassphrases = APFSVolumeEncryption.makeOperationCache()

    private let lock = NSLock()
    private var durations: [Phase: TimeInterval] = [:]
    private var hashReadBytes: Int64 = 0

    static func isMeasuring(_ value: Phase) -> Bool { phase == value }

    func didReadContent(bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        hashReadBytes += bytes
    }

    private func record(_ phase: Phase, elapsed: TimeInterval, parent: Phase?) {
        lock.lock(); defer { lock.unlock() }
        durations[phase, default: 0] += elapsed
        if let parent { durations[parent, default: 0] -= elapsed }
    }

    var measurements: [String: Double] {
        lock.lock(); defer { lock.unlock() }
        var result = Dictionary(uniqueKeysWithValues: Phase.allCases.map { ($0.rawValue, max(0, durations[$0, default: 0])) })
        result["hashReadBytes"] = Double(hashReadBytes)
        return result
    }

    static func measure<T>(_ next: Phase, _ body: () throws -> T) rethrows -> T {
        present(next)
        let start = ProcessInfo.processInfo.systemUptime
        let parent = phase
        defer { current?.record(next, elapsed: ProcessInfo.processInfo.systemUptime - start, parent: parent) }
        return try $phase.withValue(next, operation: body)
    }

    static func measure<T>(_ next: Phase, _ body: () async throws -> T) async rethrows -> T {
        present(next)
        let start = ProcessInfo.processInfo.systemUptime
        let parent = phase
        defer { current?.record(next, elapsed: ProcessInfo.processInfo.systemUptime - start, parent: parent) }
        return try await $phase.withValue(next) { try await body() }
    }

    private static func present(_ phase: Phase) {
        let stage: DataTransferStage
        switch phase {
        case .preparation: stage = .preparing
        case .scan: stage = .scanning
        case .copy: stage = .copying
        case .verification: stage = .verifying
        case .switching: stage = .switching
        case .cleanup: stage = .cleaning
        }
        progress?.begin(stage)
    }

    static func run<T>(_ body: () async throws -> T) async rethrows -> T {
        if current != nil { return try await body() }
        let session = DataTransferSession()
        defer {
            AppLogger.shared.logContext("数据操作分阶段耗时", details: session.measurements.sorted { $0.key < $1.key }
                .map { ($0.key, String(format: "%.3f", $0.value)) }, level: "PERF")
        }
        return try await $current.withValue(session) { try await measure(.preparation, body) }
    }
}
