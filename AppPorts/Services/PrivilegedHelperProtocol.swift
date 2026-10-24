import CryptoKit
import Foundation
import Security

/// 特权助手（LaunchDaemon）的固定身份。
///
/// 安装器、客户端和守护进程共用同一份常量，避免三处各写一套字符串导致
/// 「装上了但连不上」这类只能靠猜的故障。
enum PrivilegedHelperConstants {
    static let label = "com.shimoko.AppPorts.privileged-helper"
    static let machService = "com.shimoko.AppPorts.privileged-helper"
    static let launchArgument = "--privileged-helper"
    static let daemonPlistPath = "/Library/LaunchDaemons/" + label + ".plist"
    /// 助手只允许从 `/Applications` 安装：守护进程以 root 身份执行盘符里的可执行文件，
    /// 若允许从外置卷或用户可写目录启动，等于把 root 交给那个目录的写权限。
    static let installableBundleRoot = "/Applications"
    static var daemonPlistURL: URL { URL(fileURLWithPath: daemonPlistPath) }

    /// 协议版本。握手时与客户端比对，不一致就要求重装，避免新旧接口互相调用。
    ///
    /// v2 起握手带回的是签名身份指纹而不是 cdhash（见 `CodeIdentity`）。字段类型没变，
    /// 但含义变了，所以必须升版本：否则旧助手回一个 base64 cdhash，客户端只会认为
    /// 「身份不一致」，用户看到的是一串看不懂的乱码，而不是「需要重装」。
    static let protocolVersion = "2"
}

/// 一份代码签名身份的可比较摘要。
///
/// 这里刻意不再只认 cdhash。cdhash 每次重新构建都会变，于是「换了一个签名身份」和
/// 「只是重新编译了一次」在下游看起来完全一样，后果是每次出包都要求用户重装一次助手、
/// 再输一次密码。签名身份本身是稳定的，按强度分三层比较：
///
/// - 有 Team ID（Developer ID / Apple Development）：只认 identifier + Team。
///   重新编译、证书续期都不影响，这才是「装一次长期有效」的前提。
/// - 没有 Team 但有叶子证书（本机自签的 Code Signing 证书）：认 identifier + 叶子证书指纹。
/// - 两者都没有（adhoc）：只能退回 cdhash，重新构建后必须重装。
///
/// 无论哪一层，调用方都必须先通过 `SecCodeCheckValidity`：被改写过的副本在这里就出局。
enum CodeIdentity {
    struct Snapshot: Equatable, Sendable {
        var identifier: String
        var teamIdentifier: String?
        /// 叶子证书 DER 的 SHA-256 前缀；adhoc 签名没有证书。
        var leafCertificateDigest: String?
        var cdHash: String?
    }

    /// 读取一份代码的签名信息。运行中的 `SecCode` 要先落成静态代码对象才能取信息。
    static func snapshot(for code: SecCode) -> Snapshot? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return snapshot(of: staticCode)
    }

    /// 读取静态代码对象（磁盘上的镜像）的签名信息。
    ///
    /// 必须带 `kSecCSSigningInformation`：默认标志位下返回的字典里**没有**
    /// `kSecCodeInfoCertificates`，Team 信息也不一定在。少了这个标志，证书那一层判定
    /// 永远不会命中，所有构建都会静默退化成 adhoc —— 这正是「签名换了却仍要求重装」
    /// 那种最难查的故障。
    static func snapshot(of staticCode: SecStaticCode) -> Snapshot? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }

        let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String ?? ""
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let cdHash = (dictionary[kSecCodeInfoUnique as String] as? Data)?.base64EncodedString()

        return Snapshot(
            identifier: identifier,
            teamIdentifier: team?.isEmpty == false ? team : nil,
            leafCertificateDigest: certificates?.first.map { digest(of: $0) },
            cdHash: cdHash
        )
    }

    static func snapshotForCurrentProcess() -> Snapshot? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else { return nil }
        return snapshot(for: code)
    }

    /// 把快照压成一个可比较的字符串。顺序即优先级：Team > 叶子证书 > cdhash。
    static func fingerprint(_ snapshot: Snapshot) -> String {
        if let team = snapshot.teamIdentifier, !team.isEmpty {
            return "team|\(snapshot.identifier)|\(team)"
        }
        if let certificate = snapshot.leafCertificateDigest, !certificate.isEmpty {
            return "cert|\(snapshot.identifier)|\(certificate)"
        }
        if let cdHash = snapshot.cdHash, !cdHash.isEmpty {
            return "adhoc|\(snapshot.identifier)|\(cdHash)"
        }
        return "unsigned|\(snapshot.identifier)"
    }

    /// 当前进程的指纹。adhoc 构建下它会随每次重新构建而变，这是签名本身决定的，
    /// 不是这里可以绕开的东西。
    static let currentFingerprint: String? = snapshotForCurrentProcess().map(fingerprint)

    /// 指纹的人读形式，用于日志与提示：`team|com.shimoko.AppPorts|MQ7XG7WM3F` → `team:MQ7XG7WM3F`。
    static func shortKind(_ fingerprint: String) -> String {
        let parts = fingerprint.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return fingerprint }
        switch parts[0] {
        case "team": return "team:" + parts[2]
        case "cert": return "cert:" + String(parts[2].prefix(12))
        case "adhoc": return "adhoc:" + String(parts[2].prefix(8))
        default: return String(parts[0])
        }
    }

    /// 证书只用来做同一性比较，取 SHA-256 前 16 字节足够，也让日志里不至于出现一长串。
    private static func digest(of certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        let hash = SHA256.hash(data: data)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// 特权助手对外只暴露挂载类操作。
///
/// 这里刻意不接受「任意可执行文件 + 任意参数」，也刻意不接受 shell 脚本：
/// 容器卷的创建、删除等一次性操作仍然走原来的一次性授权（会弹密码），
/// 只有反复发生的挂载/卸载/重挂才由助手代劳。
@objc protocol AppPortsPrivilegedHelperProtocol {
    /// 执行一条已通过 `PrivilegedMountCommand` 校验的挂载类命令。
    ///
    /// - Parameters:
    ///   - status: 进程退出码；助手自身拒绝执行时返回 `-1`。
    ///   - standardOutput: 标准输出；解码失败或为空时长度为 0。
    ///   - standardError: 标准错误，同时也是拒绝理由的载体。
    func runMountCommand(_ executable: String,
                         arguments: [String],
                         reply: @escaping (Int32, Data, Data) -> Void)

    /// 自报协议版本与自身的签名身份指纹。
    ///
    /// 客户端据此判断守护进程是不是「同一个发布者签的、接口仍然兼容」的镜像。
    /// 指纹按 Team ID / 证书 / cdhash 三级取值（见 `CodeIdentity`），
    /// 因此用同一张证书重新构建的应用不会因为镜像变了就要求用户重装助手。
    func handshake(reply: @escaping (String, String) -> Void)
}

/// 挂载类命令白名单。
///
/// 规则是「命令 + 词法形状」两层：先限定可执行文件与子命令，再限定每个参数必须是
/// 绝对路径或已知标志。助手用 `Process` 直接执行、不经过 shell，因此这里不需要
/// 防注入，只需要防止把 `diskutil` 的破坏性子命令（eraseVolume、deleteVolume …）
/// 带进来。
enum PrivilegedMountCommand {
    static let diskutilPath = "/usr/sbin/diskutil"
    static let mountPath = "/sbin/mount"
    static let umountPath = "/sbin/umount"

    static let allowedExecutables: Set<String> = [diskutilPath, mountPath, umountPath]

    /// `diskutil` 里允许提权的子命令。`info -plist` 本身不需要 root，
    /// 但挂载后的身份复核会紧跟一条 `info`，放行它可以省掉一次授权往返。
    private static let allowedDiskutilVerbs: Set<String> = [
        "mount", "unmount", "mountDisk", "unmountDisk", "info"
    ]

    /// 参数里允许出现的独立标志位。带值的标志位（`-o`、`-t`）单独校验取值。
    private static let allowedFlags: Set<String> = ["-plist", "-force", "-u", "-o", "-t", "-w"]

    /// 校验并返回可以交给助手的参数；返回 nil 表示这条命令不该用助手。
    static func validate(executable: String, arguments: [String]) -> [String]? {
        guard allowedExecutables.contains(executable), !arguments.isEmpty, arguments.count <= 12 else { return nil }
        // 参数必须先过词法层：任何一项不合规就整条命令退出助手通道。
        for argument in arguments {
            guard !argument.isEmpty, argument.utf8.count <= 1024,
                  !argument.contains("\0"), !argument.contains("\n"), !argument.contains("\r") else { return nil }
        }
        switch executable {
        case diskutilPath:
            guard let verb = arguments.first, allowedDiskutilVerbs.contains(verb) else { return nil }
            guard arguments.dropFirst().allSatisfy(isPathOrFlag) else { return nil }
            return arguments
        case mountPath:
            // 只接受原地重挂：`mount -u [-o <options>] [-t <type>] <mountpoint>`。
            // 不带 `-u` 的 mount 会挂载新文件系统，超出「容器卷维护」范围。
            guard arguments.contains("-u") else { return nil }
            guard hasMountPoint(arguments) else { return nil }
            guard optionValuesAreSafe(arguments) else { return nil }
            guard arguments.allSatisfy({ isPathOrFlag($0) || isMountOptionList($0) || isFilesystemType($0) }) else { return nil }
            return arguments
        case umountPath:
            var paths = 0
            for argument in arguments {
                if argument == "-f" { continue }
                guard isPath(argument) else { return nil }
                paths += 1
            }
            return paths == 1 ? arguments : nil
        default:
            return nil
        }
    }

    /// 命令是否在助手的职责范围内（客户端用来决定「先问助手还是直接弹密码」）。
    static func isSupported(executable: String, arguments: [String]) -> Bool {
        validate(executable: executable, arguments: arguments) != nil
    }

    private static func isPath(_ argument: String) -> Bool {
        guard argument.hasPrefix("/"), argument.count > 1, !argument.contains("//") else { return false }
        let components = argument.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains { $0 == "." || $0 == ".." }
    }

    private static func isPathOrFlag(_ argument: String) -> Bool {
        isPath(argument) || allowedFlags.contains(argument)
    }

    /// `-o` 的值：只允许逗号分隔的挂载选项字符。
    private static func isMountOptionList(_ argument: String) -> Bool {
        !argument.isEmpty && argument.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "," || character == "=" || character == "_" || character == "-" || character == ".")
        }
    }

    private static func isFilesystemType(_ argument: String) -> Bool {
        isMountOptionList(argument)
    }

    private static func hasMountPoint(_ arguments: [String]) -> Bool {
        arguments.contains(where: isPath)
    }

    /// `-o`/`-t` 后面必须紧跟一个合法取值，且不能是路径（路径只能作为挂载点出现一次）。
    private static func optionValuesAreSafe(_ arguments: [String]) -> Bool {
        var index = 0
        var mountPoints = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-o" || argument == "-t" {
                guard index + 1 < arguments.count else { return false }
                let value = arguments[index + 1]
                guard argument == "-o" ? isMountOptionList(value) : isFilesystemType(value) else { return false }
                index += 2
                continue
            }
            if isPath(argument) { mountPoints += 1 }
            index += 1
        }
        return mountPoints == 1
    }
}
