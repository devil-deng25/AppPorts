'use client';
import SearchDialog from '@/components/search';
import { RootProvider } from 'fumadocs-ui/provider/next';
import { type ReactNode } from 'react';
const translations = {
  'Copy Markdown(page actions)': '复制 Markdown',
  'Copied Markdown(page actions)': '已复制 Markdown',
  'Search(search trigger)': '搜索文档',
  'Open Search(search trigger)(aria-label)': '搜索文档',
  'Search(search dialog)': '搜索文档',
  'Close Search(search dialog)(aria-label)': '关闭搜索',
  'No results found(search dialog)': '没有找到相关内容',
  'Search failed(search dialog)': '搜索暂时不可用',
  'Search failed, showing results for {query}(search dialog)': '搜索失败，显示“{query}”的结果',
  'On this page(table of contents)': '本页目录',
  'No Headings(table of contents)': '本页没有小标题',
  'Next Page(pagination)': '下一篇',
  'Previous Page(pagination)': '上一篇',
  'Open Sidebar(sidebar)(aria-label)': '打开目录',
  'Close Sidebar(sidebar)(aria-label)': '关闭目录',
  'Collapse Sidebar(sidebar)(aria-label)': '收起目录',
  'Toggle Menu(home layout header)(aria-label)': '打开菜单',
  'Light(theme switcher)(aria-label)': '浅色',
  'Dark(theme switcher)(aria-label)': '深色',
  'System(theme switcher)(aria-label)': '跟随系统',
  'Toggle Theme(theme switcher)(aria-label)': '切换主题',
  'Copy Text(code block)(aria-label)': '复制代码',
  'Copied Text(code block)(aria-label)': '已复制',
  'Copy Anchor Link(heading anchor)(aria-label)': '复制章节链接',
  'Copied Anchor Link(heading anchor)(aria-label)': '已复制章节链接',
};
export function Provider({ children }: { children: ReactNode }) {
  return <RootProvider search={{ SearchDialog }} i18n={{ translations }}>{children}</RootProvider>;
}
