# Agent Note: 迁移前提示目标盘不保存文件所有者

Status: implemented

## Problem

issue #78 报告 clash-verge 在数据目录迁移后无法启动系统服务：特权服务以管理员身份核对应用数据目录的所有者，看到 uid 99 而当前账户是 501，于是按 `AppDataRootNotOwned`（1012）拒绝启动内核。数据本身完整，复制与校验也都通过，Finder 与普通应用都正常。

根因不在复制，而在目标盘：exFAT/FAT32 没有 POSIX 所有者字段；HFS+ 以忽略所有权的方式挂载时，新建对象会被写成 uid 99。macOS 对非 root 调用者把 99 投影成调用者自己，所以用户在本机永远看不到这个值，只有以管理员运行的服务才看得到。这类错误提示给出的 `sudo chown` 在忽略所有权的卷上会被内核静默丢弃，用户反复尝试也无法修好。

AppPorts 之前对普通数据目录与自选文件夹的迁移不检查目标盘，任何格式都允许，也没有说明归属会丢失。用户只能事后撞上应用级故障，而此时数据已经在外盘上。

## Decision

符号链接迁移（普通数据目录、自选文件夹）在确认目标时用 `OwnershipStorageAdvisory` 做一次只读判断，命中时在确认框中补一句说明，不阻断继续：

- `exfat` / `msdos` / `fat`：文件系统没有所有者字段，一律提示；
- `hfs` 且挂载标志含 `MNT_IGNORE_OWNERSHIP`：提示，并给出访达里取消「忽略此宗卷上的所有权」后重迁的路径；
- `apfs` 无论是否 noowners 都不提示——APFS 在忽略所有权的挂载下仍保存真实 UID/GID，提示会变成误报；
- 其余类型（`smbfs`、`ntfs`、读不到）保持安静，不猜。

检测只读：`statfs` 目标位置最近的已存在父目录，不创建卷、不改设置、不弹授权。`OwnershipStorageAdvisory.Probe` 可注入，测试用假实现，不碰真实磁盘。

数据目录侧接在 `DataDirsView.presentMigrationConfirmation`，普通与经典模式两条确认路径都会带上提示；自选文件夹的「迁移所选」先展示一次汇总提示，新增目录且在添加页选择目标后迁移时，说明直接写在该 sheet 的最终位置下方——那里点「迁移」就立即开始，再叠一层弹窗会和 sheet 的关闭动画抢显示。

提示与文档都明确说 `sudo chown` 无效，避免用户继续执行注定被内核丢弃的命令。

## Related decisions

- 复制侧对 noowners 目标的容忍与「源/目标分别解释所有权」不因此改变，见[普通数据复制分别遵守源与目标所有权语义](../../implemented/architecture/2026-10-09-data-ownership-compatibility.md)。本篇只决定「迁移前是否提示」，不改复制与校验语义。
- 容器数据的挂载迁移仍走各自的 APFS 预检，普通目录不继承该要求，见[按当前任务进行 APFS 迁移预检](../../implemented/feature/2026-09-24-apfs-migration-preflight.md)。本篇不扩大容器要求，也不新增阻断条件。
- 容器卷使用 noowners 且仍保持真实归属的依据见[普通 APFS 数据卷显式使用 noowners 与系统建卷](../../implemented/bug-fix/2026-10-13-apfs-noowners-volume-creation.md)。

## Alternatives considered

- **禁止迁移到不保存所有权的盘**：能彻底避免这类故障，却会挡住只有一块 exFAT 盘的用户；仓库既有原则也反对把容器卷的格式要求推广到普通内容。且多数应用并不检查归属。
- **只在挂载标志含 `MNT_IGNORE_OWNERSHIP` 时提示**：实现更省事，但会把所有 noowners 挂载的 APFS 盘一起报进去，而 APFS 上归属是保住的，属于大面积误报。
- **迁移后扫描并为存量记录补提示**：能救已经迁坏的用户，但扫描需要额外的卷类型查询与 UI 状态，且用户真正需要的是「还原到本机」这个动作。本次按最小改动先救迁移前的人，存量用户由 FAQ 与 issue 回复覆盖。
- **在 AppPorts 里代为 chown**：内核在忽略所有权的卷上丢弃该修改，执行也不会改变结果，反而让用户以为已修复。
- **不提示，只在文档里说明**：文档只有主动查的人会看到，而这个故障表现为完全无关的应用报错，用户很难联想到目标盘格式。

## Consequences

用户在迁移前就知道目标盘存不住归属，以及哪些做法真的有用；误报范围被限制在确实不保存所有者的文件系统上。代价是多一次 `statfs`（只读、忽略失败）与一条新增用户可见文案；非 APFS 用户会看到一条不阻断的提示，需要在弹窗里多点一次「继续迁移」（自选文件夹汇总提示）。

提示现已覆盖全部 22 种语言，英文占位由[本地化覆盖与占位守卫](../../implemented/testing/2026-10-23-本地化覆盖与英文占位守卫.md)补齐并审计。存量迁移不做回溯提示；应用本体迁移（stub portal）不写应用数据，因此不在这条提示的范围内。

## Verification

`AppPortsTests/OwnershipStorageAdvisoryTests` 覆盖文件系统分类、APFS 不误报、读不到时保持安静、文案不出现 `chown`/`sudo` 且两种限制的处置不同，以及真机探针沿缺失目标向上找到盘。`LocalizationAuditTests` 全部通过；Debug 构建通过。

机制证据来自源码而非本次真机 root 视角观测：xnu `vnode_attr_handle_uid_and_gid` 在 `MNT_IGNORE_OWNERSHIP` 下把 `KAUTH_UID_NONE` 记为 99，并在非 root 调用时替换成调用者 uid；HFS+ `mount_hfs` 将 `hfs_uid` 设为 `UNKNOWNUID`（99）并 `vfs_setowner`；msdosfs `getattr` 固定返回 `uid=99`；`vnode_setattr` 在忽略所有权的卷上清除 `va_uid`/`va_gid`，说明 chown 会被丢弃。APFS 保留真实归属由本机镜像实验确认：noowners 挂载下新建文件后以 owners 重新挂载，uid 仍为 501。本次未在有 root 权限的物理 exFAT 盘上复核服务端报错。
