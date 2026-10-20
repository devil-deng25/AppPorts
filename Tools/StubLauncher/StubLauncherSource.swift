import Cocoa
import os

/// AppPorts Stub Portal Native Launcher
///
/// Replaces the bash launcher script in macOS Stub Portals.
/// Receives `kAEOpenDocuments` Apple Events and forwards them
/// to the real app on external storage.
///
/// Companion file at Contents/Resources/real_app_path.txt contains
/// the path to the real .app bundle.

/// Localization for the "external storage missing" system dialog.
///
/// This launcher runs as its own process, separate from the AppPorts app,
/// so it cannot use the app's `.localized` helper. Instead it picks the
/// message in the Mac's system language and falls back to English.
///
/// The translations mirror the `外部存储未连接，请连接后重试。` and `好`
/// entries in `Localizable.xcstrings` — keep both in sync.
enum DiskMissingStrings {
    /// (message, OK button title) keyed by xcstrings language code.
    static let table: [String: (message: String, button: String)] = [
        "en":          ("External storage is not connected. Connect it and try again.", "OK"),
        "ar":          ("وحدة التخزين الخارجية غير متصلة. صِلها ثم حاول مرة أخرى.", "موافق"),
        "de":          ("Externer Speicher ist nicht verbunden. Verbinden Sie ihn und versuchen Sie es erneut.", "OK"),
        "eo":          ("Ekstera konservejo ne estas konektita. Konektu ĝin kaj reprovu.", "Bone"),
        "es":          ("El almacenamiento externo no está conectado. Conéctalo e inténtalo de nuevo.", "Aceptar"),
        "fr":          ("Le stockage externe n'est pas connecté. Connectez-le, puis réessayez.", "OK"),
        "hi":          ("बाहरी स्टोरेज कनेक्ट नहीं है। उसे कनेक्ट करके फिर कोशिश करें।", "ठीक है"),
        "id":          ("Penyimpanan eksternal belum tersambung. Sambungkan lalu coba lagi.", "Oke"),
        "it":          ("L'archiviazione esterna non è collegata. Collegala e riprova.", "OK"),
        "ja":          ("外部ストレージが接続されていません。接続してからもう一度お試しください。", "OK"),
        "ko":          ("외부 저장소가 연결되어 있지 않습니다. 연결한 뒤 다시 시도하세요.", "확인"),
        "nl":          ("Externe opslag is niet aangesloten. Sluit deze aan en probeer het opnieuw.", "OK"),
        "pl":          ("Pamięć zewnętrzna nie jest podłączona. Podłącz ją i spróbuj ponownie.", "OK"),
        "pt":          ("O armazenamento externo não está conectado. Conecte-o e tente novamente.", "OK"),
        "ru":          ("Внешний накопитель не подключен. Подключите его и повторите попытку.", "ОК"),
        "th":          ("ยังไม่ได้เชื่อมต่อที่จัดเก็บข้อมูลภายนอก โปรดเชื่อมต่อแล้วลองอีกครั้ง", "ตกลง"),
        "tr":          ("Harici depolama bağlı değil. Bağlayıp yeniden deneyin.", "Tamam"),
        "vi":          ("Bộ nhớ ngoài chưa được kết nối. Hãy kết nối rồi thử lại.", "OK"),
        "zh-Hans":     ("外部存储未连接，请连接后重试。", "好"),
        "zh-Hant":     ("外部儲存裝置未連接，請連接後再試。", "好"),
    ]

    /// Picks the best entry for the user's preferred languages, defaulting to English.
    static var current: (message: String, button: String) {
        for preferred in Locale.preferredLanguages {
            // Try progressively shorter prefixes, e.g.
            // "zh-Hant-TW" → "zh-Hant" → "zh", "en-US" → "en".
            let components = preferred.split(separator: "-").map(String.init)
            var count = components.count
            while count > 0 {
                let candidate = components[0..<count].joined(separator: "-")
                if let entry = table[candidate] { return entry }
                count -= 1
            }
            // Generic Chinese with no script subtag → Simplified.
            if components.first == "zh" { return table["zh-Hans"] ?? ("外部存储未连接，请连接后重试。", "好") }
        }
        return table["en"] ?? ("External storage is not connected. Connect it and try again.", "OK")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.shimoko.AppPorts.StubLauncher", category: "launch")
    private var canTerminate = false
    private var receivedOpenRequest = false
    private var pendingRequests = 0
    private var failed = false

    func readRealAppPath() -> String {
        guard let resURL = Bundle.main.resourceURL else { return "" }
        let pathFile = resURL.appendingPathComponent("real_app_path.txt")
        return (try? String(contentsOf: pathFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func start() {
        // Some launchers start the process without delivering an initial open
        // event. AppKit can then defer didFinishLaunching until a second click.
        // Bootstrap from the event loop itself, independently of that event.
        DispatchQueue.main.async {
            self.canTerminate = true
            if !self.receivedOpenRequest { self.openRealApplication(urls: []) }
            self.terminateIfFinished()
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openRealApplication(urls: filenames.map { URL(fileURLWithPath: $0) }, replyToFiles: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openRealApplication(urls: urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // An in-flight launch already activates the real app. Repeated clicks
        // must not enqueue competing launches while it is starting.
        if pendingRequests == 0 && !failed { openRealApplication(urls: []) }
        return false
    }

    private func openRealApplication(urls: [URL], replyToFiles: Bool = false) {
        receivedOpenRequest = true
        logger.info("Opening target; forwarded URLs: \(urls.count)")
        let path = readRealAppPath()
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            failed = true
            logger.error("Target missing: \(path, privacy: .public)")
            showExternalDiskMissing()
            if replyToFiles { NSApp.reply(toOpenOrPrint: .failure) }
            terminateIfFinished()
            return
        }
        pendingRequests += 1
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let completion: (NSRunningApplication?, Error?) -> Void = { application, error in
            DispatchQueue.main.async {
                self.pendingRequests -= 1
                let succeeded = application != nil && error == nil
                if replyToFiles { NSApp.reply(toOpenOrPrint: succeeded ? .success : .failure) }
                if !succeeded && !self.failed {
                    self.failed = true
                    self.logger.error("Launch failed: \(String(describing: error), privacy: .public)")
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
                    alert.messageText = chinese ? "无法打开应用" : "Unable to open application"
                    alert.informativeText = path + "\n\n" + (error?.localizedDescription ??
                        (chinese ? "系统未能完成启动，请重试。" : "The system could not complete the launch. Try again."))
                    alert.runModal()
                }
                self.terminateIfFinished()
            }
        }
        let applicationURL = URL(fileURLWithPath: path)
        if urls.isEmpty {
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration,
                                               completionHandler: completion)
        } else {
            NSWorkspace.shared.open(urls, withApplicationAt: applicationURL,
                                    configuration: configuration, completionHandler: completion)
        }
    }

    private func terminateIfFinished() {
        // Acknowledge every request before exiting, even when AppKit never
        // receives the initial open event from the invoking launcher.
        if canTerminate && pendingRequests == 0 { NSApp.terminate(nil) }
    }

    /// Wraps a string as an AppleScript double-quoted literal, escaping `\` and `"`.
    private func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func showExternalDiskMissing() {
        let strings = DiskMissingStrings.current
        let script = "display dialog \(appleScriptLiteral(strings.message)) "
            + "buttons {\(appleScriptLiteral(strings.button))} default button 1 with icon caution"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
        proc.waitUntilExit()
    }
}

// Manual NSApplication setup — no MainMenu.xib
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Match LSUIElement in the portal plist. A prohibited policy changes the
// process to BackgroundOnly, which can suppress the first open event.
app.setActivationPolicy(.accessory)
delegate.start()
app.run()
