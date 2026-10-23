# Agent Note: 「锁定目录结构」改为只补回可操作项之上的锁定祖先

Status: implemented

## Problem

应用数据页的两个可见性开关单独勾选时都没有效果，只有同时勾上才会出现锁定行：

```swift
if isMigrationUnsupported && !showNonMigratableDirectories { return false }  // 第三道门
if !isMigratable { return showLockedStructure }                              // 第二道门
```

`isMigrationUnsupported` 是 `!isMigratable` 的子集，而子集之外那些“不能迁移但还能接回/挂载/恢复”的行本来就被 `needsRecoveryOrAttention` 强制显示。于是「显示锁定目录结构」能多显示的内容只剩空集：勾上它，列表纹丝不动，用户只会怀疑开关坏了。

同时两个开关的语义也没有区分开：它们覆盖的行完全重叠，等于同一个过滤器的两道锁。

## Decision

把两个开关拆成两种不同的问题：

- **显示锁定目录结构**（`showLockedStructure`）只在树层生效：补回**可操作项之上的锁定祖先**，用来交代层级。没有可操作子项的锁定目录不会因为打开它而出现。判定在 `DataDirTree.visibleItems`：

  ```swift
  guard showLockedStructure, !showNonMigratableDirectories else { return base }
  let prefix = item.path.standardizedFileURL.path + "/"
  return basePaths.contains { $0.hasPrefix(prefix) }
  ```

- **显示不支持迁移目录**（`showNonMigratableDirectories`）保持“全量放出”的语义，作用在 `DataDirItem.matchesVisibility` 的单条判断上。

明确的路径冲突、策略读取失败和非个人快捷入口的现有软链先保留检查入口，不被“不支持迁移”过滤器隐藏。普通个人目录入口仍隐藏；没有显式故障或可恢复记录、仅大小读取不全的真正锁定目录仍跟随“不支持迁移”开关。显示例外不授予迁移权限。

`matchesVisibility` 因此回到两个参数：它只回答“这一条本身该不该出现”，祖先补充交给树层，避免让单条判断依赖兄弟节点。

表头计数改为按最终渲染的行数统计（`visibleLibraryItemCount`），否则补回的祖先行会让“显示 X / 67”和列表对不上。

`DataDirTree.visibleTree` 的 `showNonMigratableDirectories` 默认值改为 `false`：默认只显示可操作内容，需要更多内容由调用方显式打开。

## Verification

- 独立 harness 编译真实模型文件（`DataDirItem.swift`、`DataDirTree.swift`、`DataPathPolicy.swift`、`PartialWeChatMigrationPolicy.swift`）验证 13 条规则：默认隐藏锁定行、打开「锁定结构」只补可操作项的祖先、无子项的锁定目录不出现、打开「不支持迁移」全量出现、零字节开关互不影响。全部通过。
- Release `xcodebuild clean build` 通过，无编译错误。
- 测试调用点已同步：`DataDirPresentationTests`、`DataDirTreeTests`、`DataPathPolicyTests`、`DataDirScannerTests`、`MigrationSafetyRenderTests`；`DataDirTreeTests` 的可见性矩阵新增了“只开锁定结构不放出孤立锁定目录”和“打开不支持迁移后全量出现”两组断言。

## Alternatives considered

- **合并成一个开关**：行为最简单，但用户明确需要“看层级”和“看全部”两种不同的浏览方式，合并会丢失前者。
- **保持原状，只让第三个开关自动打开第二个**：仍然没有解决「锁定结构」本身没有内容可显示的问题，等于留一个装饰性开关。
- **在单条判断里补祖先**：`matchesVisibility` 只能看到自己，判断“是否有可操作子项”需要遍历兄弟节点，会把树结构的知识塞进单条模型。
- **把祖先补充放在视图层**：可见性规则会分散到 View 和 Model 两处，测试也只能覆盖一半。

## Consequences

收益：两个开关各自回答一个问题——“这层结构是什么”与“还有哪些不能迁移的东西”。单独勾任何一个都有可见效果。

代价与边界：

- 「锁定结构」补回的祖先行没有独立操作，只用于展示；它们的大小仍按行统计，父行与子行不能相加。
- 祖先判定按路径前缀在**当前分组内**计算，跨类型分组（例如 Application Support 与 Containers）之间的层级不会被补回。
- 用户目录快捷入口（Desktop/Downloads 等）即使作为祖先也不会补回，避免把个人目录当成应用数据展示。
- `visibleTree` 的默认参数由 `true` 改为 `false`，未显式传参的调用方（主要是测试）行为随之收紧。

## 2026-10-23 CI regression verification

GitHub Actions [39878791223 / 120170860283](https://github.com/wzh4869/AppPorts/actions/runs/39878791223/job/120170860283) 的必需回归步骤在 `DataDirPresentationTests` 记录 10 个问题：旧测试把已链接目录也当作应隐藏项，并在启用锁定结构时仍期待祖先消失；同时真正的冲突/读取失败和普通现有软链被过早的不支持迁移判断隐藏。原失败在本机相同源码快照复现后，修复过滤优先级，测试分别断言关闭/开启祖先补回与可检查链接的行为，保留个人快捷入口隐藏和大小排除断言。

定向执行 86 项 XCTest（含还原父路径安全、56 项扫描、目录树与路径策略）和 9 项 Swift Testing，全部通过；日志位于本机 `build/Validation/ci-fix-20261023/targeted.log`。全量业务回归仍由推送后的隔离 CI runner 运行，不在开发机执行真实磁盘集成矩阵。

本轮最终源码另执行 14 项本地化审计全部通过，普通 Release clean build（arm64/x86_64）成功，笔记结构与 diff 检查通过；日志见本机 `build/Validation/ci-fix-20261023/`。
