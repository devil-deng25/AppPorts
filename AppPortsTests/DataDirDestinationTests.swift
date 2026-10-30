import XCTest
@testable import AppPorts

/// 外部存储目标路径的公式只有一份：`~/Library` 下按 Library 相对路径镜像，
/// 其余位置退化为「类型目录/目录名」。
///
/// 这里锁住的是**回归点**：随应用迁移曾经单独用「外部根 + 目录名」计算目标，
/// 两个同名但不同类型的目录（`Caches/com.deepseek.dsh` 与
/// `HTTPStorages/com.deepseek.dsh`）于是抢同一个目标，后者必然失败并报
/// 「目标路径已存在真实目录，无法覆盖」。
final class DataDirDestinationTests: XCTestCase {
    private let externalRoot = URL(fileURLWithPath: "/Volumes/External/app")
    private let homeDirectory = URL(fileURLWithPath: "/Users/tester")

    private func makeItem(_ relativePath: String, type: DataDirType) -> DataDirItem {
        DataDirItem(name: relativePath, path: homeDirectory.appendingPathComponent(relativePath),
                    type: type, priority: .optional, description: "")
    }

    private func destination(_ relativePath: String, _ type: DataDirType) -> String {
        makeItem(relativePath, type: type)
            .canonicalExternalDestination(under: externalRoot, homeDirectory: homeDirectory)
            .path
    }

    func testLibraryItemMirrorsItsPathBelowLibrary() {
        XCTAssertEqual(destination("Library/Caches/com.example.app", .caches),
                       "/Volumes/External/app/Caches/com.example.app")
        XCTAssertEqual(destination("Library/HTTPStorages/com.example.app", .httpStorages),
                       "/Volumes/External/app/HTTPStorages/com.example.app")
        XCTAssertEqual(destination("Library/Application Support/com.example.app", .applicationSupport),
                       "/Volumes/External/app/Application Support/com.example.app")
        XCTAssertEqual(destination("Library/WebKit/com.example.app", .webKit),
                       "/Volumes/External/app/WebKit/com.example.app")
    }

    /// 同名不同类必须落在不同目标上——这正是修复前失败的那一条。
    func testSameNameUnderDifferentTypesNeverShareOneDestination() {
        let caches = destination("Library/Caches/com.deepseek.dsh", .caches)
        let storages = destination("Library/HTTPStorages/com.deepseek.dsh", .httpStorages)
        XCTAssertNotEqual(caches, storages)
        XCTAssertEqual(caches, "/Volumes/External/app/Caches/com.deepseek.dsh")
        XCTAssertEqual(storages, "/Volumes/External/app/HTTPStorages/com.deepseek.dsh")
    }

    func testNestedDirectoryKeepsItsIntermediateLevels() {
        XCTAssertEqual(destination("Library/Application Support/com.example/Shared/Data", .applicationSupport),
                       "/Volumes/External/app/Application Support/com.example/Shared/Data")
    }

    func testDotFolderFallsBackToTypeFolder() {
        XCTAssertEqual(destination(".npm", .dotFolder),
                       "/Volumes/External/app/\(DataDirType.dotFolder.rawValue)/.npm")
    }

    func testPathOutsideLibraryFallsBackToTypeFolder() {
        let outside = URL(fileURLWithPath: "/opt/toolkit/data")
        let item = DataDirItem(name: "data", path: outside, type: .custom, priority: .optional, description: "")
        XCTAssertEqual(item.canonicalExternalDestination(under: externalRoot, homeDirectory: homeDirectory).path,
                       "/Volumes/External/app/\(DataDirType.custom.rawValue)/data")
    }

    /// 家目录之外但名字里带 `Library` 的路径不能被当成 Library 目录镜像走。
    func testLibraryLookingPathOutsideHomeIsNotMirrored() {
        let item = DataDirItem(name: "com.example.app", path: URL(fileURLWithPath: "/Users/other/Library/Caches/com.example.app"),
                               type: .caches, priority: .optional, description: "")
        XCTAssertEqual(item.canonicalExternalDestination(under: externalRoot, homeDirectory: homeDirectory).path,
                       "/Volumes/External/app/Caches/com.example.app")
    }
}
