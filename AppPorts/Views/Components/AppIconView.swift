//
//  AppIconView.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI
import AppKit

/// 应用图标异步加载视图
struct AppIconView: View {
    let url: URL
    var size: CGFloat = 40

    @State private var icon: NSImage? = nil
    @State private var iconRevision = 0

    var body: some View {
        Group {
            if let icon = icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .appPortalPresentationDidChange)
            .receive(on: DispatchQueue.main)) { notification in
            guard let changedURL = notification.object as? URL,
                  changedURL.standardizedFileURL.path == url.standardizedFileURL.path else { return }
            AppIconLoader.shared.invalidate(url)
            iconRevision += 1
        }
        .task(id: IconRequest(url: url, revision: iconRevision)) {
            let loaded = await AppIconLoader.shared.load(url)
            guard !Task.isCancelled else { return }
            icon = loaded
        }
    }

    private struct IconRequest: Hashable {
        let url: URL
        let revision: Int
    }
}

/// A serial worker keeps filesystem/Launch Services reads off the UI thread and
/// coalesces repeated requests through a bounded, thread-safe memory cache.
private final class AppIconLoader: @unchecked Sendable {
    static let shared = AppIconLoader()
    private let queue = DispatchQueue(label: "AppPorts.app-icons", qos: .userInitiated)
    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 512
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func load(_ url: URL) async -> NSImage? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let key = url.standardizedFileURL as NSURL
                if let image = cache.object(forKey: key) {
                    continuation.resume(returning: image)
                    return
                }
                let image = Self.loadIcon(from: url).map(Self.decodedThumbnail)
                if let image { cache.setObject(image, forKey: key, cost: 144 * 144 * 4) }
                continuation.resume(returning: image)
            }
        }
    }

    func invalidate(_ url: URL) {
        queue.async { [self] in
            cache.removeObject(forKey: url.standardizedFileURL as NSURL)
        }
    }

    /// Decode and downsample on the worker, so scrolling only draws a small bitmap.
    private static func decodedThumbnail(_ image: NSImage) -> NSImage {
        var rect = CGRect(x: 0, y: 0, width: 144, height: 144)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 144, height: 144, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: 144, height: 144))
        guard let bitmap = context.makeImage() else { return image }
        return NSImage(cgImage: bitmap, size: NSSize(width: 48, height: 48))
    }

    private static func loadIcon(from appURL: URL) -> NSImage? {
        let fm = FileManager.default
        let path = appURL.path

        // 方式 1: NSWorkspace
        if fm.fileExists(atPath: path) {
            let icon = NSWorkspace.shared.icon(forFile: path)
            // 检查是否为 iOS app（有 Wrapper/WrappedBundle），尝试提取真实图标
            if let iosIcon = loadIOSAppIcon(from: appURL) {
                return iosIcon
            }
            return icon
        }

        // 方式 2: 解析符号链接后重试
        let resolved = appURL.resolvingSymlinksInPath()
        if resolved.path != path, fm.fileExists(atPath: resolved.path) {
            return NSWorkspace.shared.icon(forFile: resolved.path)
        }

        // 方式 3: 从 bundle .icns 直接读取
        for tryPath in [path, resolved.path] {
            guard fm.fileExists(atPath: tryPath) else { continue }
            guard let plist = NSDictionary(contentsOfFile: tryPath + "/Contents/Info.plist"),
                  let iconFile = plist["CFBundleIconFile"] as? String else { continue }
            let icnsName = iconFile.hasSuffix(".icns") ? iconFile : iconFile + ".icns"
            let icnsPath = tryPath + "/Contents/Resources/" + icnsName
            if let data = try? Data(contentsOf: URL(fileURLWithPath: icnsPath)),
               let img = NSImage(data: data) {
                return img
            }
        }

        // 最终回退
        return NSWorkspace.shared.icon(forFile: path)
    }

    /// 从 iOS app 的 Wrapper/ 目录提取 AppIcon PNG
    private static func loadIOSAppIcon(from appURL: URL) -> NSImage? {
        let fm = FileManager.default
        let wrapperDir: URL
        if fm.fileExists(atPath: appURL.appendingPathComponent("Wrapper").path) {
            wrapperDir = appURL.appendingPathComponent("Wrapper")
        } else if fm.fileExists(atPath: appURL.appendingPathComponent("WrappedBundle").path) {
            wrapperDir = appURL.appendingPathComponent("WrappedBundle")
        } else {
            return nil
        }

        // 查找内部 .app
        guard let innerApps = try? fm.contentsOfDirectory(at: wrapperDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
              let innerApp = innerApps.first(where: { $0.pathExtension == "app" }) else {
            return nil
        }

        // 查找最大的 AppIcon PNG
        guard let iconFiles = try? fm.contentsOfDirectory(at: innerApp, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
              let largestIcon = iconFiles
                .filter({ $0.lastPathComponent.hasPrefix("AppIcon") && $0.pathExtension == "png" })
                .max(by: { a, b in
                    (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 <
                    (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
                }) else {
            return nil
        }

        return NSImage(contentsOf: largestIcon)
    }
}
