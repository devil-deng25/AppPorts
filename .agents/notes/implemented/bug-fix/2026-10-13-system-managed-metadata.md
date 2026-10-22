# Agent Note: 区分系统管理的标签与可移植应用元数据

Status: implemented

> 迁移自 docs/apfs-wechat-validation-2026-10-13.md
> 迁移自 docs/apfs-cross-app-validation-2026-10-14.md

## Problem

真实微信附件的内容和 inode 未变，macOS 添加的 `com.apple.macl`、`com.apple.provenance` 却使严格清理把旧副本视为独立修改。复制已切换成功，内部暂存仍占空间，普通用户无法完成操作。

## Decision

在已提交的 provenance 窄例外上，将 MACL 纳入系统管理属性，并统一 `TreeCopySession` 的处理：两项均不复制、不删除，也不以其变化判定内容变化。其他应用 xattr、权限、普通 ACL、资源叉和内容继续按对应复制契约验证。

所有采集、回放、比较与删除判断使用同一窄例外；不能为让清理通过而改变持久化内容基线或移除未知属性。还原最新数据仍必须来自当前有效位置。

系统文档跟踪标记 `UF_TRACKED` 同样属于对象本地状态：`TreeCopySession.validateFlags` 接受源端携带它，采集的可移植 flags 只保留 `UF_HIDDEN | UF_NODUMP`，不回放或比较跟踪位。该例外不扩大为接收 `UF_APPEND`、`UF_DATAVAULT` 或未知标记；不支持的位仍拒绝，并报告路径、实际位及允许范围。此规则来自当前复制器实现，此次未执行原生跟踪文件实验。

## Existing evidence

2026-10-02 的 a6ffc90 已排除精确的 `com.apple.provenance`：原生实验中 fremovexattr 返回成功后该属性仍在，原实现不再复制/删除它，清单可保留诊断值但便携元数据比较排除它。因此 provenance 不是 10 月 13 日首次发现或首次豁免。

2026-10-13 来源记录 build 26 因附件 MACL 变化暂停清理，build 27 修复后自动完成；来源保留首轮失败，不能算一次成功。两项 `systemManagedAttributes` 的统一采集、回放、比较与删除路径使用同一窄例外。

> 补充来源：合订归档 AppPorts-调查大合订-20261009 / 原始报告快照/I/实施验收/restore-noowners-compat/报告.md（S061），及同归档 S060 的 syscall 证据。

## Related decisions

- provenance 例外出现时的历史还原契约见[历史严格还原只映射目标根所有权](../../implemented/bug-fix/2026-10-02-legacy-volume-restore-ownership.md)。

- 本篇是元数据处理的窄例外，严格复制基线见[目录显示、执行权限与严格数据复制分开约束](../../implemented/architecture/2026-10-01-data-path-copy-safety.md)。

[卷状态适配](../architecture/2026-10-22-volume-state-adaptation.md)复用复制器普通 `.DS_Store` 例外，新增业务内容与非普通同名对象继续阻止删除。

## Alternatives considered

- **逐字节比较所有 xattr**：边界简单，但把操作系统授权标签的正常变化当成应用内容冲突。
原文档未记录第二个独立候选方案。窄名单不能被扩展为忽略或删除所有 xattr；这是一项保护限制，不冒充当时实际评估过的方案。

## Consequences

只改变 MACL/provenance 时不误拒绝已证明冗余的旧副本，改变应用自定义 xattr、内容、ACL 或其他被要求保留的元数据时仍拒绝删除；复制和清理不主动写删两项系统标签。

代价与边界：名单不自动扩展为所有 `com.apple.*` 属性；系统语义变化或其他属性触发误报时，应先查明归属与可移植性，不能按命名猜测。文件 SHA-256 相同不证明全部 xattr 相同，IINA 严格签名问题仍保留独立验证缺口。
