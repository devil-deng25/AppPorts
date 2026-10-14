#!/usr/bin/env python3
"""Add timing and an isolated XCTest harness to a disposable v1.9.0 checkout.

Copy algorithms and data protection are unchanged. Startup/log/default-store
isolation is test infrastructure, not part of the product being compared.
"""
import argparse
from pathlib import Path
import subprocess


def prepare(current, baseline):
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=baseline, text=True).strip()
    if revision != "ef823d1345d594aae6a0b3e99fbd452bc4e10bab":
        raise RuntimeError("The baseline must be the disposable v1.9.0 checkout")

    def original(path):
        return subprocess.check_output(["git", "show", "HEAD:" + path], cwd=baseline, text=True)

    def write(path, value):
        destination = baseline / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(value)

    def replace(value, old, new):
        if value.count(old) != 1:
            raise RuntimeError("Instrumentation anchor is not unique: " + old[:100])
        return value.replace(old, new)

    write("AppPorts/Utils/DataTransferSession.swift", (current / "AppPorts/Utils/DataTransferSession.swift").read_text())
    write("AppPortsTests/APFSLifecycleBenchmarkTests.swift", (current / "AppPortsTests/APFSLifecycleBenchmarkTests.swift").read_text())
    support = (current / "AppPortsTests/AppPortsRealMountValidationTests.swift").read_text()
    support = support[support.index("func requireRealMount("):]
    support = "import Darwin\nimport Foundation\nimport XCTest\n@testable import AppPorts\n\n" + support
    support += """
enum DurableFileIO {
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize()
        try file.close()
    }
}
"""
    write("AppPortsTests/APFSBenchmarkFixture.swift", support)
    # This host never builds a production scene or starts login agents.
    write("AppPorts/Appports.swift", """import SwiftUI
@main struct AppMoverApp: App {
    var body: some Scene { WindowGroup { Color.clear.frame(width: 1, height: 1) } }
}
""")
    logger = original("AppPorts/Services/AppLogger.swift")
    logger = replace(logger, "    nonisolated var logFileURL: URL {", """    nonisolated var logFileURL: URL {
        if let root = ProcessInfo.processInfo.environment["APPPORTS_REAL_MOUNT_ROOT"] {
            return URL(fileURLWithPath: root).appendingPathComponent("baseline-benchmark.log")
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("APLifecycleBaseline-test.log")
        }""")
    write("AppPorts/Services/AppLogger.swift", logger)
    store = original("AppPorts/Services/ContainerMountStore.swift")
    store = replace(store, "    private static var defaultFileURL: URL {", """    private static var defaultFileURL: URL {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("APLifecycleBaseline-\\(getpid())-records.plist")
        }""")
    write("AppPorts/Services/ContainerMountStore.swift", store)

    copier = original("AppPorts/Utils/FileCopier.swift")
    copier = replace(copier, "    ) async throws -> Int64 {\n        try Task.checkCancellation()", """    ) async throws -> Int64 {
        if !DataTransferSession.isMeasuring(.copy) {
            return try await DataTransferSession.measure(.copy) {
                try await self.copyDirectory(from: source, to: destination, estimatedTotalBytes: estimatedTotalBytes,
                    removeQuarantine: removeQuarantine, progressHandler: progressHandler)
            }
        }
        try Task.checkCancellation()""")
    copier = replace(copier, "while let item = enumerator.nextObject() as? URL {",
        "while let item = DataTransferSession.measure(.scan, { enumerator.nextObject() as? URL }) {")
    copier = replace(copier, "let values = try item.resourceValues(forKeys: Set(keys))",
        "let values = try DataTransferSession.measure(.scan) { try item.resourceValues(forKeys: Set(keys)) }")
    write("AppPorts/Utils/FileCopier.swift", copier)
    migrator = original("AppPorts/Utils/ContainerVolumeMigrator.swift")
    migrator = replace(migrator,
        "    private func performCleanup(_ cleanup: ContainerCleanupRecord, recordUpdateOnly: Bool = false) async -> CleanupWarning? {",
        """    private func performCleanup(_ cleanup: ContainerCleanupRecord, recordUpdateOnly: Bool = false) async -> CleanupWarning? {
        if !DataTransferSession.isMeasuring(.cleanup) {
            return await DataTransferSession.measure(.cleanup) { await self.performCleanup(cleanup, recordUpdateOnly: recordUpdateOnly) }
        }""")
    lines = migrator.splitlines(keepends=True)
    for index, line in enumerate(lines):
        if "try fileManager.moveItem(at:" in line and line.rstrip().endswith(")"):
            indentation = line[:len(line) - len(line.lstrip())]
            lines[index] = indentation + "try DataTransferSession.measure(.switching) { " + line.strip() + " }\n"
    write("AppPorts/Utils/ContainerVolumeMigrator.swift", "".join(lines))
    disk = original("AppPorts/Utils/DiskUtility.swift")
    disk = replace(disk, '        _ = try await run(["mount", "nobrowse", "-mountPoint", mountPoint.path, volume])',
        '        _ = try await DataTransferSession.measure(.switching) { try await self.run(["mount", "nobrowse", "-mountPoint", mountPoint.path, volume]) }')
    # Keep the exact original force/unmount algorithm; measure its existing command.
    lines = disk.splitlines(keepends=True)
    within_unmount = False
    for index, line in enumerate(lines):
        if "func unmount(" in line:
            within_unmount = True
        if within_unmount and "_ = try await run(arguments)" in line:
            lines[index] = line.replace("try await run(arguments)", "try await DataTransferSession.measure(.switching) { try await self.run(arguments) }")
            within_unmount = False
    write("AppPorts/Utils/DiskUtility.swift", "".join(lines))
    (baseline / "build/Validation").mkdir(parents=True, exist_ok=True)
    patch = subprocess.check_output(["git", "diff", "--", "AppPorts"], cwd=baseline)
    (baseline / "build/Validation/instrumentation.patch").write_bytes(patch)
    print(baseline)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    args = parser.parse_args()
    prepare(Path(__file__).resolve().parent.parent, args.baseline.resolve())
