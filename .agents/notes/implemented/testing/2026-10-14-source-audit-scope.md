# Agent Note: 源码审计只约束接线，不承诺运行时行为

Status: implemented

## Problem

副本管理页面移除后，扫描测试名称仍宣称需要副本管理。警示弹窗审计将展示点数量当成正确性条件，并允许其他文件的同名变量或单纯置空满足触发检查。锁接线检查用整段精确字符串定位，找不到函数时还可能把整个文件当成函数体。

## Decision

保留未完成事务阻止再次迁移的行为断言，只更新扫描测试名称。删除弹窗展示点数量下限，保留统一关闭入口检查。赋值审计只搜索声明所在文件的非 nil 赋值表达式，并用正反例约束匹配器；命名和注释明确它不证明运行时可达。

锁测试保留已有实际并发互斥、失败释放与调用点审计。启动维护调用允许空白和参数变化；维护函数定位必须明确匹配，避免分割失败静默退化为全文。其余调用点检查仍是源码接线约束，不把字符串顺序解释为完整控制流证明。本次不为测试整理改动生产迁移架构。

## Existing note audit

检索 WarningSheet、OperationLock 没有找到现有专属决定。扩展检索源码、弹窗和测试审计的命中涉及 APFS 业务、签名、进度或笔记流程，与本次接线匹配规则无关。
[测试状态隔离](2026-10-01-test-state-isolation.md)与[隔离验收](../../implemented/testing/2026-10-12-apfs-validation-evidence.md)约束本次运行环境，决定没有被替代，不归档。旧权限、格式升级和保留事务测试仍负责兼容行为，不因旧名称批量删除。

## Alternatives considered

- 保留原审计：改动最少，但会阻止合理减少弹窗，也可能把仅关闭弹窗误判为可触发。
- 删除全部源码审计或改造生产服务以完全行为化：前者丢失调用点防线，后者能改善可测试性但扩大到迁移业务，超出本次清理范围。保留明确限定能力的补充审计。

## Consequences

删除历史数量门槛后，合理删减页面不再误报。匹配器仍不是 Swift 解析器，不能区分同文件全部词法作用域或证明工厂函数返回非空；涉及跨文件状态重构时应重新审视检查方式，不能为了通过检查加入无效赋值。

验证使用独立 XCTest 宿主运行 WarningSheetDismissalAuditTests、OperationLockTests 和 DataDirScannerTests；另做 Release clean build。未运行真实应用迁移，本次结果不替代 APFS 用户流程验收。

## Verification

2026-10-14，Xcode 27.0（27A266a）Release clean build 成功。独立宿主定向执行 DataDirScannerTests 55 项、OperationLockTests 7 项、WarningSheetDismissalAuditTests 3 项，全部通过，无跳过。笔记树、格式、归档校验通过。日志和摘要保存在本地 build/Validation/test-audit-20261014；临时 DerivedData 与 xcresult 验证后清理。
