import Carbon
import Foundation

/// Retain the same script identity across an application's exchange and cleanup
/// commands so macOS can reuse its administrator authorization. No credentials
/// are stored by AppPorts; the system still decides whether to prompt again.
final class AdministratorAuthorization: @unchecked Sendable {
    static let shared = AdministratorAuthorization()

    private let lock = NSLock()
    private var script: NSAppleScript?
    private var expiresAt: TimeInterval = 0
    /// 与系统的授权空闲时限对齐。AuthServices 对 `system.privilege.admin` 的凭据
    /// 默认 5 分钟空闲才失效，这里若短于系统侧时限，会在授权还有效时先丢掉脚本，
    /// 让同一批迁移中途多弹一次密码框。改长不会延长系统侧的授权，只是不再提前放弃。
    private let reuseInterval: TimeInterval = 300

    func run(command: String) throws -> ShellCommandResult {
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()

        let now = ProcessInfo.processInfo.systemUptime
        if now >= expiresAt {
            script = nil
        }
        var errorInfo: NSDictionary?
        if script == nil {
            let candidate = NSAppleScript(source: """
                on runAuthorizedCommand(commandText)
                    do shell script commandText with administrator privileges
                end runAuthorizedCommand
                """)
            guard let candidate, candidate.compileAndReturnError(&errorInfo) else {
                return try failure(errorInfo, command: command)
            }
            script = candidate
            expiresAt = now + reuseInterval
        }

        // Pass arguments as descriptors rather than recompiling a different
        // script for each command or interpolating command text into AppleScript.
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: "runauthorizedcommand"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: command), at: 1)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        guard let script else {
            return try failure(nil, command: command)
        }
        let output: NSAppleEventDescriptor? = script.executeAppleEvent(event, error: &errorInfo)
        if let errorInfo {
            return try failure(errorInfo, command: command)
        }
        return ShellCommandResult(status: 0, standardOutput: Data((output?.stringValue ?? "").utf8),
                                  standardError: Data(), timedOut: false)
    }

    private func failure(_ errorInfo: NSDictionary?, command: String) throws -> ShellCommandResult {
        // Cancellation and failures never leave a reusable session behind.
        script = nil
        expiresAt = 0
        let number = errorInfo?[NSAppleScript.errorNumber] as? Int ?? -1
        let message = errorInfo?[NSAppleScript.errorMessage] as? String ?? "Unable to execute administrator command"
        if number == -128 {
            throw DiskUtility.Failure.administratorPromptCancelled(command: command)
        }
        return ShellCommandResult(status: 1, standardOutput: Data(),
                                  standardError: Data("\(message) (AppleScript error \(number))".utf8), timedOut: false)
    }
}
