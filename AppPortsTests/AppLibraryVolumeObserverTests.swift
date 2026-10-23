import AppKit
import XCTest
@testable import AppPorts

@MainActor
final class AppLibraryVolumeObserverTests: XCTestCase {
    func testUnmountAndReconnectRefreshBothLists() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AppLibraryVolumeObserverTests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let local = root.appendingPathComponent("Local")
        let external = root.appendingPathComponent("External")
        let offline = root.appendingPathComponent("Offline")
        let app = external.appendingPathComponent("Fixture.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.appports.volume-event-fixture",
            "CFBundleName": "Fixture", "CFBundleExecutable": "fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: app.appendingPathComponent("Contents/MacOS/fixture"))
        let portal = local.appendingPathComponent("Fixture.app/Contents")
        try fm.createDirectory(at: portal.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: portal.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let portalInfo = ["CFBundleIdentifier": "com.appports.volume-event-fixture.appports.stub",
            "CFBundleExecutable": "launcher", "AppPortsTargetBundleIdentifier": "com.appports.volume-event-fixture"]
        try PropertyListSerialization.data(fromPropertyList: portalInfo, format: .xml, options: 0)
            .write(to: portal.appendingPathComponent("Info.plist"))
        try Data("test launcher".utf8).write(to: portal.appendingPathComponent("MacOS/launcher"))
        try app.path.write(to: portal.appendingPathComponent("Resources/real_app_path.txt"), atomically: true, encoding: .utf8)

        let center = NotificationCenter()
        let observer = AppLibraryVolumeObserver(center: center)
        defer { observer.stop() }
        let scanner = AppScanner()
        let removed = expectation(description: "Unmount refreshes both panes")
        let returned = expectation(description: "Mount restores both panes")
        observer.start { isMount in
            Task { @MainActor in
                let localApps = await scanner.scanLocalApps(at: local, runningAppURLs: [], externalAppsDir: external)
                let externalApps = await scanner.scanExternalApps(at: external, localAppsDir: local)
                XCTAssertEqual(localApps.count, 1)
                if isMount {
                    XCTAssertEqual(localApps.first?.status, AppStatus.linked)
                    XCTAssertEqual(externalApps.count, 1)
                    XCTAssertEqual(externalApps.first?.status, AppStatus.linked)
                    returned.fulfill()
                } else {
                    XCTAssertEqual(localApps.first?.status, AppStatus.orphanedLink)
                    XCTAssertTrue(externalApps.isEmpty)
                    removed.fulfill()
                }
            }
        }
        try fm.moveItem(at: external, to: offline)
        center.post(name: NSWorkspace.didUnmountNotification, object: nil)
        await fulfillment(of: [removed], timeout: 10)
        try fm.moveItem(at: offline, to: external)
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        await fulfillment(of: [returned], timeout: 10)
    }

    func testStopAndRestartDiscardAlreadyQueuedEvents() async {
        let center = NotificationCenter()
        let observer = AppLibraryVolumeObserver(center: center)
        var staleCalls = 0
        var currentCalls = 0
        observer.start { _ in staleCalls += 1 }
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        observer.stop()
        let delivered = expectation(description: "Only the current observation handles the event")
        observer.start { isMount in
            XCTAssertFalse(isMount)
            currentCalls += 1
            delivered.fulfill()
        }
        center.post(name: NSWorkspace.didUnmountNotification, object: nil)
        await fulfillment(of: [delivered], timeout: 2)
        observer.stop()
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(staleCalls, 0)
        XCTAssertEqual(currentCalls, 1)
    }
}
