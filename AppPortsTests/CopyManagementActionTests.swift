import AppKit
import SwiftUI
import XCTest
@testable import AppPorts

/// Actual production SwiftUI button → view model → real isolated data service.
/// An external accessibility client presses the real button while this host
/// verifies the filesystem and both windows. Opt-in because SwiftUI virtual
/// elements are not exposed to an in-process NSAccessibility walker.
final class CopyManagementActionTests: XCTestCase {
    @MainActor
    func testFailedContinueCanBeRetriedAndCompletesInterruptedTransferInBothWindows() async throws {
        guard ProcessInfo.processInfo.environment["APPPORTS_UI_EXTERNAL_ACTION"] == "1",
              let outputPath = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"] else {
            throw XCTSkip("Run with an external accessibility client and APPPORTS_UI_EXTERNAL_ACTION=1")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPorts-UI-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home")
        let source = home.appendingPathComponent("Payload")
        let external = root.appendingPathComponent("External")
        let recordURL = root.appendingPathComponent("records.plist")
        for url in [source, external] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("The user's current data".utf8).write(to: source.appendingPathComponent("document"))
        let fault = WriteFault()
        let interruptedStore = ContainerMountStore(fileURL: recordURL, writeData: { try fault.write($0, to: $1) })
        let item = DataDirItem(name: "Payload", path: source, type: .applicationSupport, priority: .critical, description: "Fixture data", status: DataDirStatus.local)
        do {
            _ = try await DataDirMover(homeDir: home, store: interruptedStore).migrateAndComplete(item: item, to: external, progressHandler: nil)
            XCTFail("Injected persistence failure should interrupt migration")
        } catch {}
        let store = ContainerMountStore(fileURL: recordURL)
        let pending = try XCTUnwrap(store.transfers().first)
        XCTAssertTrue(pending.isPreparationRecoverable || pending.isVerifiedSwitchRecoverable)
        let mover = DataDirMover(homeDir: home, store: store)
        let failingMover = DataDirMover(homeDir: home, store: ContainerMountStore(fileURL: recordURL,
            writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) }))
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let attempts = ActionAttempts()
        let failed = XCTestExpectation(description: "First button action encounters the isolated store failure")
        let finished = XCTestExpectation(description: "Button action finishes the real transfer")
        let dependencies = CopyManagementModel.Dependencies(load: {
            do { return .init(dataGroups: DataTransferGroup.groups(from: try store.transfers())) }
            catch { return .init(readErrors: [error.localizedDescription]) }
        }, execute: { action in
            guard case .resumeData(let record) = action else { throw CocoaError(.featureUnsupported) }
            if await attempts.next() == 1 {
                defer { failed.fulfill() }
                return try await failingMover.resumeVerifiedTransfer(operationID: record.operationID, progressHandler: nil)
            }
            let result = try await mover.resumeVerifiedTransfer(operationID: record.operationID, progressHandler: nil)
            finished.fulfill()
            return result
        })
        let first = CopyManagementModel(dependencies: dependencies, operationState: state)
        let second = CopyManagementModel(dependencies: dependencies, operationState: state)
        let windows = [first, second].enumerated().map { index, model -> NSWindow in
            let window = NSWindow(contentRect: NSRect(x: 200 + index * 30, y: 200 + index * 30, width: 760, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "AppPorts UI Validation \(index + 1)"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: CopyManagementView(model: model, operationState: state)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.orderFront(nil)
            return window
        }
        defer { windows.forEach { $0.close() } }
        await first.refresh()
        await second.refresh()
        let host = try XCTUnwrap(windows.first?.contentView)
        host.layoutSubtreeIfNeeded()
        windows[0].makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        try render(host, name: "copy-management-before-continue")
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let ready: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier),
            "windowTitle": windows[0].title, "actionTitle": "继续".localized, "fixtureRoot": root.path]
        try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys])
            .write(to: output.appendingPathComponent("copy-management-ui-ready.json"), options: .atomic)
        await fulfillment(of: [failed], timeout: 180)
        for _ in 0..<40 {
            if !state.isBusy && first.errorMessage != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(state.isBusy)
        XCTAssertNotNil(first.errorMessage)
        XCTAssertFalse(first.snapshot.dataGroups.isEmpty)
        XCTAssertFalse(second.snapshot.dataGroups.isEmpty)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("document"), encoding: .utf8), "The user's current data")
        try render(host, name: "copy-management-after-failure")
        try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys])
            .write(to: output.appendingPathComponent("copy-management-ui-retry-ready.json"), options: .atomic)
        await fulfillment(of: [finished], timeout: 180)
        for _ in 0..<40 {
            if !state.isBusy && first.snapshot.dataGroups.isEmpty && second.snapshot.dataGroups.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(first.errorMessage)
        XCTAssertTrue(first.snapshot.dataGroups.isEmpty)
        XCTAssertTrue(second.snapshot.dataGroups.isEmpty, "The other open window must refresh from the same committed record")
        XCTAssertTrue(try store.transfers().isEmpty)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("document"), encoding: .utf8), "The user's current data")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), ["Payload"])
        try render(host, name: "copy-management-after-continue")
    }

    private actor ActionAttempts {
        var count = 0
        func next() -> Int { count += 1; return count }
    }

    @MainActor
    private func render(_ host: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }

    private final class WriteFault: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        func write(_ data: Data, to url: URL) throws {
            lock.lock()
            defer { lock.unlock() }
            let document = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let transfers = document?["transfers"] as? [[String: Any]] ?? []
            if !failed && transfers.contains(where: { $0["phase"] as? String == "verified" }) {
                failed = true
                throw CocoaError(.fileWriteNoPermission)
            }
            try DurableFileIO.write(data, to: url)
        }
    }
}
