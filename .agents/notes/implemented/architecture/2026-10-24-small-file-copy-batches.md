# Agent Note: 普通小文件以有界批次复制并在返回前收齐写入

Status: implemented

## Problem

完整扫描并发化之后，实际复制仍逐文件串行。保存的微信 msg 基线含 163,704 个普通文件，其中 131,323 个不超过 64 KiB；大量文件的打开、内容写入和完整元数据回放仍逐个等待。用户要求进一步优化，同时保留所有基线、同步、核验、清理授权和恢复逻辑。

## Decision

strictData 对同目录内连续的普通小文件使用最多四个工作任务，每个文件不超过 16 KiB、没有硬链接组和资源叉。目录、大文件、硬链接、资源叉、FIFO 和符号链接在批次收齐后沿原路径串行处理，appBundle 保持串行。

工作任务共享不可变清单和索引，各自持有独立复制计数和硬链接表；只调用原节点复制逻辑，不增加内容证明缓存。源和目标父描述符保持打开直到批次全部退出。成功结果按原词法顺序归并，外部进度回调仍由调用者逐项等待。取消和错误先停止批次并收齐所有工作，再允许抛错或独立恢复；Task 取消唤醒原暂停控制，批次状态不传入独立恢复。

共享复制、扫描和事务原语的修改在更新 main 前必须完成一次性 macOS runner 上的全部 regression、process、localization 和 Release clean build；本机相关套件和真实微信往返只覆盖各自边界。直接 main 提交可先用临时验证分支运行现有手动 workflow，全部检查通过后再将同一提交推进 main，不创建 PR，也不把 advisory 作业的绿色状态当成其中所有检查通过。

## Existing-note audit

- [完整扫描并发](../../implemented/architecture/2026-10-24-bounded-data-scan-reads.md)部分重叠：本篇增加写入调度，扫描的证明预算和调度不变。
- [同层并发应用树复制](../../proposed/feature/2026-10-20-concurrent-app-tree-copy.md)部分重叠：本篇只处理 strictData 普通小文件；应用树、大文件及跨目录硬链接提案继续保留。
- [严格数据复制](../../implemented/architecture/2026-10-01-data-path-copy-safety.md)、[持久化事务](../../implemented/architecture/2026-10-10-verified-transfer-lifecycle.md)和[自动恢复](../../implemented/architecture/2026-10-12-apfs-automatic-recovery.md)继续约束所有检查与独立恢复，不被替代。

## Alternatives considered

- 增大数据缓冲区：对大文件有可能有益，但当前缓冲区已按文件大小分配，上述多数文件小于 64 KiB，不能消除逐文件元数据等待。
- 并发整棵树和全部节点：可能覆盖更多延迟，但目录描述符和跨目录硬链接会增加同步范围，本轮限制为连续普通小文件。
- 打包复制或减少核验：能减少部分文件系统往返，但改变可恢复材料及删除依据，不满足用户保留现有兜底的要求。
- 只跑相关迁移套件和实盘往返：验证快且接近用户场景，但遗漏共享复制器的正常退出调用者，已有 CI 失败证明该范围不足；保留局部验证，再以完整 CI 范围约束 main 更新。

## Threshold evidence

初始1 MiB资格在内盘合成ABBA中有收益；解锁后外盘ABBA发现64 KiB文件四路复制约3.295秒，串行约1.408秒，含原同步与校验总时间约4.366秒对2.361秒。进一步按1/2/4/4/2/1复测，4/8/16 KiB的四路结果稳定快于串行；64 KiB两路约3.280秒，四路一轮3.329秒、一轮0.670秒，串行两轮约1.35秒。不能将更宽资格作为该外盘的稳定收益。

资格收窄为16 KiB，保留四路对大量微小文件的收益，并让64 KiB等更大的文件沿原串行路径。保存的msg基线中107,489/163,704个普通文件不超过16 KiB；该历史分布只解释覆盖范围，不证明当前微信总任务提速。原始外盘对比为build/Validation/small-copy-external.json，尺寸/宽度矩阵为small-copy-external-matrix.json。

## Verification

隔离 XCTest 宿主使用最终 16 KiB 资格源码。树复制、资源叉、所有权、目录迁移、挂载迁移、准备恢复、完成、进度、冷恢复、重入、维护、任务中心和工作流审计共 331 项通过；测速用例默认跳过并单独启用。最终结果为 build/Validation/SmallCopyTinyRegression.xcresult，日志 /tmp/AppPorts-small-copy-tiny-regression.log。补充应用事务此前 75 项通过，一项损坏无关记录测试失败；修改前的既有扫描优化测试产品中同一测试也在损坏记录解码时失败，证据为 SmallCopyBaselineFailure.xcresult。没有删除或放宽该断言。该重试路径的整库读取缺陷现由[弹盘暂停准入](../feature/2026-10-23-explicit-disk-ejection.md)记录修复，应用事务 76 项和相关暂停回归均已通过。

新增用例比较串行/四路完整清单、元数据、跨目录硬链接、资源叉和完整有序回调序列，并用实际数据 seek barrier 证明工作重叠且不超过四路，TaskLocal 测量继承及三倍完整散列读取保持一致。Task 取消与单工作 I/O 故障后，全部工作收齐且候选停止变化，源不变，独立重试仍成功。首文件回调可能发生在同批第二文件完成后，准备恢复测试同时跑 1/4 路：串行保留真正部分副本，四路检查已写文件的完整内容；两者都验证返回后不再写入、基线未完成、事务未切换，并在冷账本上取消或继续恢复。16 KiB/16 KiB+1/64 KiB 实际 seek 重叠边界用例保证资格两边分别并发和串行；元数据/取消夹具为 4 KiB，继续覆盖真正的工作重叠。

提交 3d0c1d5 的 [CI](https://github.com/wzh4869/AppPorts/actions/runs/40044855803) 中，682 项 Swift Testing 全部通过，XCTest 正常退出真实复制用例因“首文件回调后第二文件必须不存在”的串行假设失败；本机修改前 CIQuitBefore.xcresult 复现相同断言。生产取消、恢复落盘和原件保全断言均通过，不能据此删除第二文件或改变批次收齐顺序。该退出用例现在在独立夹具上覆盖 1/4 路：串行保留第二文件不存在的原断言，四路在首文件回调、请求退出之前从冷账本定位候选并逐字节检查首批四个文件，返回后再次检查；两者都拒绝第五文件启动，并核对恢复记录落盘后才回复退出、候选停止变化、基线为空、事务未切换及冷账本取消成功。仅在任务返回后检查内容不能证明回调前已收齐，回调当场检查守住这一时序边界。最终隔离宿主 AppOperationStateTests 五项通过，结果 build/Validation/CIQuitFinal.xcresult，日志 /tmp/AppPorts-ci-quit-final.log；这是局部证据，不代替完整 CI。

Xcode 在报告夹具异常时卡在 CoreSymbolicationDT；临时 xctestrun 去掉 libRPAC/PERFC 性能诊断注入并以 XCTDisableAggressiveSymbolication 禁止进程内积极符号化，保留 XCTest、MainThreadChecker、所有测试和断言。以上配置只修改忽略的构建产品，没有改系统访问保护、FDA 或测试宿主写入用户账本的拒绝条件。

最终普通产品的 arm64/x86_64 Release clean build 成功，未注入 get-task-allow，deep/strict 签名验证及原安装版指定要求核对通过；构建日志 /tmp/AppPorts-small-copy-tiny-release.log。

最终同一 Debug 构建使用 6,000 个 4 KiB、16 KiB 或 64 KiB 文件，每组按 1/4/4/1 路运行，完整预读、原同步和三遍散列保留。内盘 4/16 KiB 复制阶段中位数分别为 1.308 → 0.830 秒、1.494 → 0.961 秒，含扫描、同步、校验的总时间为 2.019 → 1.516 秒、2.334 → 1.813 秒。外盘相应复制时间为 1.532 → 1.041 秒、1.735 → 1.023 秒，总时间为 2.329 → 1.744 秒、2.622 → 1.868 秒。64 KiB 在两种宽度设置下实际都串行；内盘总时间为 3.130/3.208 秒，外盘为 3.475/3.325 秒，没有初始宽资格测试的显著回退。

夹具都位于自建 UUID 目录并在完成后移除，原始结果为 build/Validation/small-copy-tiny-internal.json 和 small-copy-tiny-external.json，测试结果为 SmallCopyTinyInternal.xcresult 和 SmallCopyTinyExternal.xcresult。这些是同构建合成文件组，不能据此承诺整个真实微信任务固定比例提速。锁屏时外盘试运行停在自有夹具的 mkdir 并停止；解锁后的正式外盘测试成功。

微信 business 卷使用最终 Release 诊断宿主，以 1/4/4/1 路执行四轮生产 restoreAndComplete/migrateAndComplete。每轮 1,766 个节点、134,607,593 字节，迁回和迁出后均另行完整核验内容与元数据；其他卷及链账本、保留材料、重挂阻断记录和弹盘暂停文件均核对不变，待恢复/待清理为空。复制阶段迁回中位数 0.585/0.624 秒、迁出 0.536/0.505 秒；总时间相应为 5.982/5.931 秒、6.765/5.955 秒。该混合小目录总时间主要由 APFS 准备、切换、收尾决定，四轮的总时间差不能全部归因于复制调度。报告为 build/Validation/small-copy-real-wechat-20261024-064459/results.json。

诊断宿主位于忽略的构建目录，只将当前产品入口替换为已授权的实盘测试入口；其余生产源码逐文件核对相同，签名及指定要求与安装版一致，没有 get-task-allow。操作仍持有 OperationLock、WriterAdmission 和 ApplicationLaunchProtection，拒绝加密/锁定卷和运行中的写入者；每轮从当前账本解析 UUID，不复用已删除卷的 UUID。微信通过应用菜单正常退出，测试前已确认相关进程与卷上 lsof 均为空。失败即停止并保留生产恢复账本，不手工恢复旧 plist 或删除材料。

微信 msg 卷使用同一最终 Release 宿主完成四路资格的一轮完整往返，172,982 个节点、33,528,214,034 字节；当前基线 163,704 个普通文件中 107,479 个符合 16 KiB 且无硬链接/资源叉的资格。迁回复制 168.369 秒、核验 184.883 秒、总时间 480.950 秒；迁出复制 312.871 秒、核验 119.246 秒、收尾 194.617 秒、总时间 712.171 秒。迁回和迁出均另行完整核验内容与元数据，结果 passed，清理完成；最终 msg UUID 为 A85C3B50-2842-40A7-8D1D-7283EB1342E2。其他账本集合及弹盘暂停文件核对不变，其他两个卷保持挂载，待恢复/待清理/保留材料均为空。报告为 build/Validation/small-copy-real-wechat-20261024-064645/msg-1-copies4/result.json。

msg 这一轮没有同构建串行对照，不用于宣称整体提速。大文件字节量与原有完整读取校验、清理仍占明显时间；不能把合成微小文件组的比例推广到这个完整任务。

最终普通新版在 operation.lock 互斥保护下原子替换 /Applications/AppPorts.app；替换前的完整安装包保存在 build/Validation/small-copy-install-20261024-071046/AppPorts-previous.app。安装包可执行文件 SHA-256 为 d1cbcdd117bca081f3ed12429d36589ceaa1024ba656261041a9f850d90d8f73，登录代理刷新到 CDHash a33601c4ec40fae4494116a779ef720b4d893b5d，代理退出 0。安装及正常启动前后挂载账本和弹盘暂停文件逐字节一致，三个卷保持挂载，待恢复/待清理为空。已观察最终安装版正常主窗口及空闲任务中心；微信已重新启动到原登录窗口。报告为同目录 install-report.json，阶段界面另有 28 个组合渲染验证。

## Consequences

16 KiB资格保留微小文件的提速，同时避免已观察到的更大外盘文件回退；大于16 KiB的普通文件仍串行，因此不会得到这一调度的性能收益。

Swift 工作任务和每批归并存在调度开销，快盘上可能抵消收益，机械盘寻道也可能变慢。已完成的文件进度在批次收齐后回调，最大延迟限定为四个小文件；取消不得把仍在写入的目标交给清理。
