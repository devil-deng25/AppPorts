# AppPorts 文档站

本文件只约束 User_docs。应用源码遵循仓库根目录规则。

- Fumadocs 本地预览只处理简体中文。现有 docs Markdown 是正文源，.content 与 public 是生成产物。
- 目录重排和全文重写需要维护者单独批准；框架适配不构成批准。其他语言仅在明确要求后同步。
- 面向普通用户。操作页先说明适用情况，再给步骤、结果和问题入口。术语首次出现时解释，按钮名称须与应用一致。
- 参考 https://developers.google.com/style：标题明确、句子简洁、指令具体，避免夸张承诺和无证据的结论。
- 原理与操作分开。实验只呈现条件、过程、结果和限制；不包含对话、个人账号或真实个人路径。实测与推测分开。
- 开发：npm ci；npm run docs:dev。改正文后重新运行开发命令以更新生成内容。
- 验证：npm run docs:build；npm run docs:typecheck；npm run docs:check；浏览器检查搜索、主题、手机导航和旧链接。
- 保留 sponsors.json、latest.json、logo.png 的站点根路径。不要把预览直接部署为八语站点替代品。
- 决策笔记只写在仓库根的 .agents/notes，遵循根目录 vendored skill。
