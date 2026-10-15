# Agent Note: 所有权测试镜像仅对忙碌卸载做有限重试

Status: implemented

## Problem

提交 87b6bd9 的 CI 在 TreeCopyOwnershipTests.partialCleanupAfterReconnect 中，
hdiutil detach 返回 Resource busy，夹具立即记录失败。日志没有记录占用者，
无法区分短暂系统访问与持续泄漏；本次失败并非 latest.json 日期解析失败。

## Decision

OwnershipTestImage 的正常卸载最多尝试五次，仅对未超时的 EBUSY 退出码重试，
间隔为 250、500、1000、2000 毫秒。成功后才更新 attached 状态；其他错误、
超时和取消不重试。最终失败时采集有输出和时间上限的 lsof 卷占用信息，
仍然让测试失败，并保留未卸载镜像。夹具不使用 force，不跳过重连后的内容验证。

注入命令执行器和等待函数验证重试边界，真实镜像用例继续验证完整的断开、
重连和清理流程。此改动不改变生产迁移或卸载策略。

## Related decisions

检索活跃笔记后，[所有权兼容](../architecture/2026-10-09-data-ownership-compatibility.md)、
[测试状态隔离](2026-10-01-test-state-isolation.md) 和
[APFS 验证](2026-10-12-apfs-validation-evidence.md) 与本篇部分重叠，仍各自有效；
建卷与历史还原笔记不涉及夹具重试，无需替代或归档。

## Alternatives considered

- 单次卸载：失败最快，但把短暂占用直接变成整个回归失败，且没有占用诊断。
- 强制卸载：能驱逐占用者，但会掩盖真实资源泄漏，也不再验证正常断开流程。
- 只重跑整个测试：容易实施，却重复迁移且丢失首次占用现场；只重试卸载更窄。

## Consequences

短暂忙碌可恢复，持续占用仍暴露；代价是最多增加四次命令与 3.75 秒等待，
最终诊断另有五秒上限。占用者可能在诊断前退出，lsof 也可能权限不足，
因此诊断不能保证找到原因，不能把重试通过解释为已证明没有资源泄漏。

## Verification

2026-10-15 本机 macOS 27.0.1 的修改前定向用例通过，未稳定复现 CI 忙碌。
修改后 `TreeCopyOwnershipTests` 与 `OwnershipImageDetachTests` 共 13 项测试通过，
包括真实 APFS 镜像重连和五组注入结果的重试边界、等待取消。CI 当时占用者
仍未知；新增诊断用于下次持续失败取证。生产迁移实现保持不变。
