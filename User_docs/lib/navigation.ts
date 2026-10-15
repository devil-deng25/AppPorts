import type { Root, Node } from 'fumadocs-core/page-tree';
import { source } from './source';
import { entries } from './docs-structure';
import { createElement } from 'react';
import { AppWindow, BookOpen, BookA, Rocket, Boxes, Tags, FolderOpen, HardDrive, ShieldCheck, RefreshCw, Settings, CircleHelp, ScrollText, FlaskConical, Heart, Scale, Lock, Undo2, History, Newspaper, FolderLock, Archive, FileText, type LucideIcon } from 'lucide-react';
const icons: Record<string, LucideIcon> = { AppWindow, BookOpen, BookA, Rocket, Boxes, Tags, FolderOpen, HardDrive, ShieldCheck, RefreshCw, Settings, CircleHelp, ScrollText, FlaskConical, Heart, Scale, Lock, Undo2, History, Newspaper, FolderLock, Archive };
const names = new Map(entries.flatMap(entry => [entry, ...(entry.children ?? [])]).map(entry => [entry.name, entry.icon]));

export function docsTree(): Root {
  function decorate(node: Node): Node {
    const icon = createElement(icons[names.get(String(node.name)) ?? ''] ?? FileText, { size: 17, strokeWidth: 1.6, 'aria-hidden': true });
    return node.type === 'folder' ? { ...node, icon, children: node.children.map(decorate) } : { ...node, icon };
  }
  return { ...source.pageTree, children: source.pageTree.children.map(decorate) };
}

export function pageSection(url: string): { name: string; url: string } {
  if (url === '/docs/archive/overview') return { name: '项目', url: '/docs/AppPorts' };
  if (url.startsWith('/docs/archive/')) return { name: '历史功能归档', url: '/docs/archive/overview' };
  if (url === '/docs/contributing') return { name: '项目', url: '/docs/AppPorts' };
  for (const entry of entries) {
    if (entry.children?.some(child => `/docs/${child.slug}` === url)) {
      return { name: entry.name, url: `/docs/${entry.children[0].slug}` };
    }
  }
  return { name: '文档', url: '/docs/AppPorts' };
}
