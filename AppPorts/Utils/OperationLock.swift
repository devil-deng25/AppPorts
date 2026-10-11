//
//  OperationLock.swift
//  AppPorts
//

import Darwin
import Foundation

/// 跨进程互斥锁：让「登录代理」和「AppPorts 主应用」不要同时去动同一批挂载点。
///
/// 登录代理监听 `/Volumes`（见 `ContainerMountAgentInstaller.launchAgentPayload`），
/// 外置卷一有变化它就会立刻跑一遍；而 AppPorts 自己做挂载迁移、挂载、卸载、还原时
/// 也会挂载和卸载卷 —— 于是就有了「用户正在 AppPorts 里还原，代理同时插进来抢同一个
/// 挂载点」的竞态。
///
/// 代理是独立进程，看不到主应用内存里的 `AppOperationState`，所以这里用文件锁跨进程协调：
/// 同一时刻只有一个进程能持有 `~/Library/Application Support/AppPorts/operation.lock`。
/// 用 `flock` 而不是「写一个锁文件、用完删掉」：进程崩了内核会自动释放，不会留下死锁。
///
/// 约定：锁只在最外层操作拿一次、由拿到的那一层释放。不要在已经持锁时再 `tryAcquire`
/// —— 同一个实例会直接返回 `true`，多出来的那次 `release()` 会把外层的锁一起放掉。
final class OperationLock: @unchecked Sendable {
    static let shared = OperationLock()

    /// 代理等待主应用让出锁的时长；超过就跳过本次运行，等下一次卷变化或下次登录。
    static let agentWaitTimeout: TimeInterval = 120

    /// 主应用等待代理跑完的时长；代理单次运行实测约 4 秒。
    static let appWaitTimeout: TimeInterval = 15

    static var defaultFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppPorts/operation.lock")
    }

    private let fileURL: URL
    private let writerAdmissionCheck: () throws -> Void
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var lastAdmissionFailure: String?

    init(fileURL: URL = OperationLock.defaultFileURL, writerAdmissionCheck: (() throws -> Void)? = nil) {
        self.fileURL = fileURL
        self.writerAdmissionCheck = writerAdmissionCheck ?? {
            try WriterAdmission.prepareForWrite(dataDirectory: fileURL.deletingLastPathComponent())
        }
    }

    deinit { release() }

    /// Distinguishes a live incompatible writer from ordinary lock contention.
    var admissionFailureReason: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastAdmissionFailure
    }

    func recheckWriterAdmission() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        do {
            try writerAdmissionCheck()
            lastAdmissionFailure = nil
        } catch {
            lastAdmissionFailure = error.localizedDescription
            throw error
        }
    }

    /// 当前是否被**别的进程**持有。只探测、不拿锁，用来记日志判断谁在让路。
    var isHeldByAnotherProcess: Bool {
        stateLock.lock()
        let alreadyHeldBySelf = descriptor >= 0
        stateLock.unlock()
        guard !alreadyHeldBySelf else { return false }

        guard let probe = openDescriptor() else { return false }
        defer {
            _ = flock(probe, LOCK_UN)
            _ = close(probe)
        }
        // flock 的锁跟着「打开的文件描述」走，所以同一个进程里另开一个 fd 也能探到冲突。
        return flock(probe, LOCK_EX | LOCK_NB) != 0
    }

    /// 试一次，不等待。已经在持锁状态时返回 `true`（不会重复计数）。
    @discardableResult
    func tryAcquire() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard checkAdmission() else { return false }
        if descriptor >= 0 { return true }

        guard let candidate = openDescriptor() else { return false }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(candidate)
            return false
        }
        // An older main app or directly launched agent can appear while this
        // operation waits for the file lock; inspect the live process list again.
        guard checkAdmission() else {
            _ = flock(candidate, LOCK_UN)
            _ = close(candidate)
            return false
        }
        descriptor = candidate
        return true
    }

    /// 最多等 `timeout` 秒。拿不到返回 `false`，由调用方决定跳过还是照常执行。
    func acquire(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if tryAcquire() { return true }
            if admissionFailureReason != nil || Task.isCancelled { return false }
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// 释放锁。没持锁时什么都不做。
    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }

    // MARK: - 私有辅助

    /// Only called while stateLock is held. A rejected attempt never owns or
    /// releases another OperationLock instance's descriptor.
    private func checkAdmission() -> Bool {
        do {
            try writerAdmissionCheck()
            lastAdmissionFailure = nil
            return true
        } catch {
            lastAdmissionFailure = error.localizedDescription
            return false
        }
    }

    private func openDescriptor() -> Int32? {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let candidate = open(fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard candidate >= 0 else { return nil }
        var info = stat()
        guard fstat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            _ = close(candidate)
            return nil
        }
        return candidate
    }
}
