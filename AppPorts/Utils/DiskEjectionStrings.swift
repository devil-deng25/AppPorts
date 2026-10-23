import Foundation

/// Maintainer-approved Chinese/English scope; remove entries when translations are completed.
enum DiskEjectionStrings {
    static let englishFallbackKeys: Set<String> = [
        "所有卷已卸载，设备仍连接。请拔下设备后重新插入。",
        "正在请求弹出，自动挂载已暂停。",
        "磁盘尚未弹出，自动挂载已暂停。",
        "磁盘已离线，请重新插入设备。",
        "无法确认磁盘是否已离线，自动挂载仍已暂停。",

        "弹出外置硬盘",
        "重试弹出",
        "弹出整块外置硬盘及其所有卷。",
        "此磁盘的自动挂载已暂停。请重新插入设备以恢复自动挂载。",
        "无法确认外置物理磁盘，请连接磁盘后重试。",
        "无法读取弹出状态，已暂停自动恢复。请重试或检查日志。",
        "无法请求 Finder 弹出磁盘。请检查自动化权限后重试。",
    ]
}
