# Agent Note: 中文文档的 Fumadocs 本地预览

Status: implemented

## Problem

现有文档使用 VitePress，GitBook 导出形成第二份内容与配置。当前需求是先在本机查看参考站同类的 Fumadocs 阅读界面，再单独批准中文目录和内容重写。框架替换不能提前执行尚未批准的七组目录，也不能影响正在修改的 AppPorts 主工作区。

## Decision

User_docs 使用 Fumadocs Base UI、Next.js 与静态导出，只加载简体中文。现有 docs Markdown 是正文源；构建准备脚本把提示框、折叠块和组件转换为忽略的 MDX 产物。lib/navigation.ts 明确保留原侧栏分组、顺序与名称，并为目录与页面提供 Lucide 图标。原 VitePress 配置及其他语言源文件保留，其他语言不进入当前构建。

后续目录、内容深度、词汇表及实验整理见[面向普通用户的文档方案](../../proposed/architecture/2026-10-15-reader-first-docs-structure.md)。该方案仍待批准，当前预览保留现有目录和正文。

首页与文档内页共用 SiteHeader，提供文档、更新日志、官网、下载、赞助、搜索和主题入口。首页只保留主标题和操作入口，不显示副标题。文档顶部显示一次分类、标题、简介，以及统一尺寸的复制 Markdown 与打开菜单；原生面包屑关闭，避免重复分类。菜单提供 Markdown 和 GitHub 源文件入口，复制与打开行为不自动发送内容。

Header 的 LanguageSwitch 提供原站八种语言，简体中文标记为当前语言，其他语言在当前标签页打开线上文档。准备脚本根据保留的译文源文件生成 .content/languages.json；存在同路径译文时转换为线上 /<lang>/<slug>.html，没有译文或从首页切换时进入该语言首页。切换不沿用中文章节锚点或查询参数。这个入口保留当前仅构建中文的边界，译文仍使用线上 VitePress 外观。

User_docs 内 GitBook 导出、脚本和配置已移除。根 sponsors.json 在构建时复制到站点根目录，latest.json 与 logo 来自 docs/public；应用代码与根目录配置不属于本次变更。

## Rendering contracts

scripts/prepare-fumadocs.mjs 将提示框转换为 Callout，折叠块转换为 details，流程图转换为 Mermaid；未知块级 HTML 与不成对容器使准备步骤失败，避免静默丢文。Vue 赞助组件替换为读取同一份 JSON 的 React 列表；隐私政策转为完整中文 Markdown，包含原联系邮箱；许可页按实际依赖更新。三篇中文研究记录中的个人路径、用户名和账号标识脱敏。

VitePress 显式章节 ID 独立保留为锚点。旧 .html 路径导出跳转页，并保留 query 与 hash。新增固定 Header 后，手机端标题与显式锚点的 scroll-margin 根据 --fd-docs-row-3 计算，包含顶部导航、文档菜单和页内目录。

可复制的正文单独生成为 public/docs-md 下的标准 Markdown：赞助组件展开为表格，Mermaid 恢复为代码块，提示与折叠块展开为可读引用。复制接口不会暴露站点专用 React 标签。图片使用浏览器直接加载；外链失败时显示紧凑占位，避免固定尺寸坏图撑开页面。

## Existing note audit

检索 proposed、implemented、rejected 中的 Fumadocs、GitBook、User_docs 与文档站。活跃笔记没有同主题框架决定。[Agent Notes 归属](../../implemented/process/2026-10-14-agent-notes-adoption.md)只约束笔记存储，不属于框架决定，无需替代；命中的自动挂载与预检查记录仅引用研究页面作为证据，与站点框架无关。

## Alternatives considered

- 保留 VitePress 并定制外观：能复用现有 Vue 组件和多语言站点，但不能完成已选定的 Fumadocs 本地预览。
- 一次性重写目录和迁移全部 MDX：长期维护更直接，但会越过目录批准边界，并扩大框架验证范围。保留原文，通过可重复生成适配。
- 跟随参考站使用 React Router：与参考实现一致；本次使用 Fumadocs 官方 Next.js 静态模板，直接得到普通静态主机可验证的产物，不引入服务端部署。
- 直接复制处理后的 MDX：可以复用页面生成结果，但会遗漏赞助组件内容并保留非标准图表标签。构建时另行输出完整 Markdown。
- 将八语全部接入本地 Fumadocs：切换语言后能保持同一外观，但需要扩展构建、导航与界面翻译。当前选择仅增加入口，复用线上译文；页级链接按本地译文清单判断，不在构建时依赖远端网络探测。

## Consequences

可以独立审阅 Fumadocs 外观，中文原文、旧链接与 App 使用的 JSON 路径得到保留。生成适配层增加构建步骤，编辑正文后需重新运行开发命令。其他语言暂未进入 Fumadocs 产物，本次不能直接作为线上八语站点的替代部署；正式切换需要确定语言与路由范围。目录重排和全文重写仍需单独批准。

依赖锁定在 package-lock.json，原 pnpm 锁文件移除，避免两个包管理器锁定不同框架。远端图片可用性仍取决于原媒体服务。旧 GitBook 本地工作区与分支的清理由独立备份保护，备份不作为本站构建输入。

语言切换依赖线上站点可用，且本地译文清单可能领先于已部署内容；正式迁移多语言时需要替换外链映射。当前没有译文的页面返回语言首页，避免生成已知缺失页面的地址。

## Verification

npm run docs:build 完成静态导出；npm run docs:typecheck 完成路由与 TypeScript 校验。npm run docs:check 核对 31 篇文档的内部链接、章节锚点、旧路径、转换失败边界、Markdown 内容及 sponsors.json/latest.json 与来源一致性。

Playwright 实际检查中文搜索、深浅色切换、流程图、折叠、赞助名单、隐私邮箱、复制 Markdown、打开菜单、共用 Header、手机目录导航与无横向溢出。复制按钮和打开按钮按参考页实测统一为 30px 高、12px 字号、6px 圆角。独立代码审查识别并修复了显式锚点丢失、翻译键上下文、原有导航分组、隐私联系方式、手机端锚点偏移与 Markdown 组件内容遗漏。

语言菜单检查覆盖八项语言、当前语言标记、Escape 关闭与焦点返回、Enter 打开、首页及缺失译文回退、深浅主题和 320–390px 手机宽度；浏览器点击 English 后抵达线上 Core Features 页面。七种语言的线上首页与 core.html 均返回 HTTP 200。

仓库要求的 Xcode Release clean build 在隔离 DerivedData 中通过；应用源码未修改。合并前仍需对照当时最新 main；当前工作仅落在 User_docs 与本篇笔记。
