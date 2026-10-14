# Agent Notes

这里保存 AppPorts 的决策理由、真实考虑过的备选方案和验证边界，帮助后续维护者理解为什么这样实现，以及哪些旧问题需要避免。

## 阅读入口

- [implemented/](implemented/)：已实现的决策记录，具体实现基线和后续修订见各篇正文。
- [proposed/](proposed/)：提案及本次历史迁移中暂待源码入库的记录。

进入类别目录或按主题搜索即可查找笔记；本页不维护逐篇索引。

## 写入与维护

动笔前先加载已入库的 [write-notes-like-deepseek skill](../../.claude/skills/write-notes-like-deepseek/SKILL.md)。何时写、模板、分类、状态流转、归档和门禁均以该 skill 为准，本页只提供入口。

项目约定见 [CLAUDE.md](../../CLAUDE.md#agent-notes-decision-records)。决策笔记统一放在本目录；旧 `docs/` 已移到仓库外保存，`User_docs/` 用于文档站。

Codex 从根目录 [AGENTS.md](../../AGENTS.md) 读取项目入口，并通过 `.agents/skills/write-notes-like-deepseek` 的相对软链接发现同一份 skill；无需另行全局安装。新增入口后，用新会话确认指令已加载；技能列表若未刷新，可重启 Codex。

## 历史迁移的过渡状态

这批文档独立于业务代码发布：部分 implemented 对应本地已提交、尚未推送的代码；部分 proposed 已有本机实现，但源码尚未提交，正文有明确标记。目录状态不能直接当作远端代码或安装版的功能清单。

阅读历史决定时应一并查看其实现基线和关联的后继决定，不能仅因旧篇位于 implemented 就恢复已被修订的默认行为。迁移范围及过渡处理见[采用 Agent Notes 的决定](implemented/process/2026-10-14-agent-notes-adoption.md)；对应代码入库时同步调整相关笔记。

## 验证

在仓库根目录运行：

```sh
npx tsx .claude/skills/write-notes-like-deepseek/scripts/verify-agent-note-tree.ts
npx tsx .claude/skills/write-notes-like-deepseek/scripts/verify-agent-note-format.ts
```
