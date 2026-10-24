# Agent Note: 总体进度与当前目录阶段使用独立显示范围

Status: implemented

## Problem

微信拆分操作将 msg 和 business 的分组进度合成任务百分比，界面却按该百分比点亮当前目录的六阶段标签。标签等距、进度权重不等距，使蓝色终点与阶段不对应。准备新卷时的临时挂载被测量为 switching，将尚未开始复制的分组提前推到 88%，两目录任务因此刚扫描就显示 44%。复制后的切换准备通知、私有卷卸载同样早于最终源/目标证明，若直接用这些事件高亮，就会在切换和校验之间反复跳动。

## Decision

总体条只展示全任务估算百分比；当前目录的阶段单独显示为六个等宽步骤，使用实际阶段高亮，并在多目录任务中显示目录索引。准备中的挂载、同步、核验及清理只推进准备范围，实际复制开始后沿用原阶段权重。正式入口切换由调用者在最后证明之后、入口提交之前以 observeEntrySwitch 单独观察；此前的 switching 仅显示为校验，不推进切换权重。真实入口切换开始后的内部核验仍属于切换；清理中的挂载与核验均保持收尾步骤。底层 stage 和每轮统计继续记录实际活动，视图用 presentationStage 呈现所属工作步骤。独立恢复观察器在原验证门禁之后记录已验证/已切换事实，仅更新显示；准备副本提升后无需重复制也能显示实际切换，独立旧副本清理显示收尾。

目录工作流在私有准备挂载前声明 tracksEntrySwitchBoundaries；只有接入正式入口观察的目录流程应用这一映射，应用包保留原 switching 事件语义。新复制在源清单扫描之前以 observeNewCopy 清空同目录前驱清理、已切换及复制进度事实，内部 preparing 不触发重置。normalizeManagedLink 的实际入口交换同样记录 observeEntrySwitch。

显示修正只作用于观察快照和视图。DataTransferProgress.begin 原有关键区间标记、MigrationExecution、操作锁、持久化状态机和完成依据保持原行为。

## Existing-note audit

- [后台任务](../../implemented/architecture/2026-10-21-后台迁移任务与异常处理.md)部分重叠：任务合算和历史语义保留，本篇替代以总体百分比点亮目录阶段的呈现。
- [真实工作阶段](../../implemented/feature/2026-10-14-data-transfer-progress.md)部分重叠：实际活动计数、速率和观察器的执行保护继续保留。

## Alternatives considered

- 按权重重排原标签：更接近单目录条的比例，但准备和扫描标签会挤在一起，且两个目录合算仍无法表示当前目录阶段。
- 把总体进度改成当前目录进度：蓝色条可以对应当前阶段，但切换到 business 时会归零，丢失全任务范围。
- 将挂载测量改为 preparing：能修正显示，却同时改变分阶段测量和观察器的关键区间标记，本篇只修正呈现与估算。

## Verification

DataTransferProgressTests 验证双目录全任务合算、下一目录重置、准备挂载不跳到后半程、关键区间保护保持原行为，以及新观察器接续已验证或已切换事务。DataPreparationRecoveryTests.completeCandidateSurvivesBaselineSave 使用 mount/symlink 两模式的真实恢复夹具，区分最终证明前的原保护通知（步骤3）与正式切换，末尾清理为步骤5，同时保留无重复制的目录身份与 addVolume 断言。DataTransferCompletionTests 用全新观察器清理保留链，检查收尾步骤与原身份、内容、清理顺序。

最终相关 331 项回归通过；普通 arm64/x86_64 Release clean build 和签名验证通过。构建日志 /tmp/AppPorts-small-copy-tiny-release.log；最终恢复回归结果位于 build/Validation/SmallCopyTinyRegression.xcresult。完整元数据、基线、同步、清理授权及独立恢复没有改变。

MigrationSafetyRenderTests/testRenderDataTransferProgressStages 渲染28个中英文/明暗/阶段组合。总体条与当前目录步骤独立，双目录切换时总体44%且步骤高亮切换，清理时高亮收尾，长路径与正文布局可读。最终渲染结果在 build/Validation/small-copy-progress-renders，测试结果 SmallCopyRender3.xcresult。安装及代理验证见[有界小文件复制](../architecture/2026-10-24-small-file-copy-batches.md)。

## Follow-up verification

新增顺序用例覆盖复制结束后的提前切换通知、私有卸载、源/目标证明、正式入口提交，以及切换/清理内部继续核验。应用包的 switching 原语义、私有准备挂载前的范围声明、同目录前驱清理后新复制重置和 normalize 实际入口交换均有回归。此类观察事件只改变显示，不调用执行控制或修改持久化事务；既有关键区间保护用例保留。

本轮隔离宿主回归 106 项 XCTest 与 229 项 Swift Testing（共335项）通过，另1项小文件性能对照 XCTest 因未设置测速目录而跳过。结果位于 build/Validation/EntryProgressRegressionFinal.xcresult，日志 /tmp/AppPorts-entry-progress-tests-final.log。独立复审未发现剩余 P1/P2；完整校验、删除授权与持久化顺序保持原行为。此轮仅修正阶段显示，没有修改旧副本删除算法或测得清理提速。

本轮 arm64/x86_64 Release clean build 与 deep/strict 签名验证通过，日志 /tmp/AppPorts-entry-progress-release-final.log。28组中英文、明暗及阶段渲染通过，结果 build/Validation/EntryProgressRender.xcresult 与 entry-progress-renders；已检查校验、切换、收尾布局。

当前任务结束且账本无待处理项后，安装版正常退出并原子替换为本轮产品。安装与启动验证位于 build/Validation/small-copy-install-20261024-075946/，旧产品保留为 AppPorts-previous.app。新安装可执行文件 SHA256 为 04b2aedc062f9157445bebd49e276f50cb26122a8afad7fd5c359b4fe275db54，CDHash 为 b46d6a4ba8f05c608943baccf998c64543697c42。代理签名身份已刷新至该 CDHash，运行路径为 /Applications/AppPorts.app/Contents/MacOS/AppPorts，代理退出0。账本与弹盘暂停文件逐字节保持不变，现场三个记录卷仍挂载，待恢复/清理为0。微信 msg/business 的 UUID 采用用户最新完成任务后的现场记录，未用前一轮测试 UUID 代替。新版界面已回到微信应用数据页面并识别 msg + business 已挂载。

## Consequences

总体百分比仍是阶段与目录合算的估值，无法承诺剩余时间。独立阶段条增加少量高度，需要在固定弹窗中检查内容及操作按钮。
