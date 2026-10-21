# Agent Note: 应用数据分栏的子视图要纵向撑满

Status: implemented

## Problem

应用数据页在“应用”列表为空（首次扫描还没回来）时，整块内容滑到窗口中间偏下：左边“应用 0”和搜索框、右边的“请从左侧选择应用”都不再贴着工具栏，下方留出一大块空白。列表加载完成后自动恢复，所以只在刚启动、快速切页时看得到。

根因不在外层容器。`HSplitView` 的两个子视图只声明了宽度约束：

```swift
VStack { ... }.frame(minWidth: 200, maxWidth: 280)          // 左栏
VStack { ... }.frame(minWidth: 340, maxWidth: .infinity)    // 右栏
```

纵向没有任何约束，SwiftUI 的 `HSplitView` 交给 AppKit 的 `NSSplitView` 后，固定高度的子视图在 autoresizing 中上下边距都是弹性的，于是被垂直居中。分栏高度等于内容理想高度（空列表时约 160pt），自然落在窗口中间。工具目录和应用页看不出来，是因为内容足够高，撑满了分栏。

先前尝试过的外层修法都无效，可作反证：`GeometryReader` 固定 `ZStack` 尺寸、`ZStack(alignment: .topLeading)`、页面加 `.frame(maxHeight: .infinity, alignment: .topLeading)`，均不能让分栏内部的内容归位。

## Decision

约束加在分栏的子视图上，让它们接受 `NSSplitView` 给出的完整高度：

```swift
VStack { ... }
    .frame(minWidth: 200, maxWidth: 280)
    .frame(maxHeight: .infinity, alignment: .top)        // 左栏

VStack { ... }
    .frame(minWidth: 340, maxWidth: .infinity)
    .frame(maxHeight: .infinity, alignment: .top)        // 右栏

HSplitView { ... }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
```

`alignment: .top` 让内容少时从顶部开始，空白留在下方；内容多时由内部的 `ScrollView` / 目录浏览器自己滚动。

## Alternatives considered

- **外层 `GeometryReader` + 固定 `ZStack` 尺寸 + `.clipped()`**：只约束了页面外框，分栏内部仍按内容高度居中，实测无效。
- **`ZStack(alignment: .topLeading)`**：同理无效，问题发生在 `NSSplitView` 的子视图高度里。
- **页面级 `.frame(maxHeight: .infinity, alignment: .topLeading)`**：同样只作用于页面外框。
- **给分栏设固定高度**：窗口大小变化时会被裁，且无法自适应。

## Consequences

收益：空列表、加载中、出错占位这些“内容很少”的状态都从顶部开始排，不再出现整页下坠。

代价与边界：

- 左栏宽度约束不变（200–280pt），右栏继续占满剩余宽度。
- 分栏最小高度仍由内容决定：窗口被压到比“头部 + 占位”还矮时会被裁切，但窗口本身有 600pt 下限，正常用不到。
- 只改 `appDirsContent`，工具目录页和应用页未受影响。

## Verification

用屏幕录制权限抓窗口截图对比同一次启动：

- 修复前：“应用 0”位于窗口高度约 43% 处，分栏整体居中；
- 修复后：“应用 0”紧贴工具栏下方的顶栏，搜索框与占位文案随之上移，下方留白。

Release 构建通过（Apple Development 证书，Team MQ7XG7WM3F），Swift 编译警告 0。
