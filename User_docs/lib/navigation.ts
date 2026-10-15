import type { Root, Node } from 'fumadocs-core/page-tree';
import { source } from './source';
import { createElement } from 'react';
import { AppWindow, BookOpen, Rocket, Boxes, Tags, FolderOpen, Terminal, HardDrive, ShieldCheck, RefreshCw, Settings, CircleHelp, Wrench, ScrollText, FlaskConical, Heart, GitPullRequest, Scale, Lock, FileText, type LucideIcon } from 'lucide-react';
const icons: Record<string, LucideIcon> = {
  AppPorts: AppWindow, faststart: Rocket, core: Boxes, badges: Tags, settings: Settings,
  'storage-guide': HardDrive, 'why-apfs': HardDrive, 'macos-27': RefreshCw,
  limitations: ShieldCheck, troubleshooting: Wrench, faq: CircleHelp, logging: ScrollText,
  changelog: ScrollText, sponsor: Heart, contributing: GitPullRequest, licenses: Scale, privacy: Lock,
  'datamigrae/baseinfo': BookOpen, 'datamigrae/tools': Terminal, 'datamigrae/operation': FolderOpen,
  'datamigrae/mount-migration': HardDrive, 'datamigrae/resign': ShieldCheck, 'datamigrae/container-identity': Lock,
};
const folderIcons: Record<string, LucideIcon> = { '数据迁移': FolderOpen, 'App 迁移策略': AppWindow, '外部存储': HardDrive, '升级与修复': ShieldCheck, '实验记录': FlaskConical };
const icon = (Icon: LucideIcon) => createElement(Icon, { size: 17, strokeWidth: 1.6, 'aria-hidden': true });


// Keep the existing VitePress navigation until the new outline is approved.
export function docsTree(): Root {
  const page = (slug: string, name: string): Node => {
    const found = source.getPage(slug.split('/'));
    if (!found) throw new Error(`Missing navigation page: ${slug}`);
    return { type: 'page', name, url: found.url, icon: icon(icons[slug] ?? (slug.startsWith('research/') ? FlaskConical : FileText)) };
  };
  const folder = (name: string, children: Node[]): Node => ({ type: 'folder', name, children, icon: icon(folderIcons[name] ?? FolderOpen) });
  return { name: 'AppPorts', children: [
    { type: 'separator', name: '指南' },
    page('AppPorts', '简介'), page('faststart', '快速开始'), page('core', '核心功能'), page('badges', '状态徽章说明'),
    folder('数据迁移', [
      page('datamigrae/baseinfo', '基础实现'), page('datamigrae/tools', '工具目录识别'), page('datamigrae/operation', '操作指南'),
      page('datamigrae/mount-migration', '挂载迁移（容器数据）'), page('datamigrae/resign', '重签名与崩溃防护'),
    ]),
    folder('App 迁移策略', [
      page('migration-strategy/portal', '迁移策略'), page('migration-strategy/strategy-map', '应用类型与策略对照'),
      page('migration-strategy/updater-detection', '自更新应用识别'), page('migration-strategy/appstore-update', 'App Store 应用更新策略'),
    ]),
    page('settings', '设置'),
    folder('外部存储', [page('storage-guide', '外部存储指南'), page('why-apfs', '为什么外置盘必须是 APFS')]),
    folder('升级与修复', [page('macos-27', 'macOS 27 升级说明'), page('datamigrae/container-identity', '容器数据、沙盒与签名身份')]),
    page('limitations', '兼容性与限制'), page('troubleshooting', '故障排除'), page('faq', '常见问题'), page('logging', '日志与诊断'),
    folder('实验记录', [
      page('research/sandbox-symlink', '沙盒应用 + 符号链接'), page('research/sandbox-mountpoint', '沙盒应用 + 挂载点'),
      page('research/unplug-test', '拔盘：APFS 卷 vs 磁盘映像'), page('research/prelogin-mount', '开机前挂载（A 实验）'),
    ]),
    page('changelog', '更新日志'), page('sponsor', '赞助'), page('contributing', '贡献者指南'), page('licenses', '开源许可'), page('privacy', '隐私政策'),
  ] };
}

export function pageSection(url: string): { name: string; url: string } {
  for (const node of docsTree().children) {
    if (node.type === 'folder' && node.children.some(child => child.type === 'page' && child.url === url)) {
      const first = node.children.find(child => child.type === 'page');
      return { name: String(node.name), url: first?.type === 'page' ? first.url : '/docs/faststart' };
    }
  }
  return { name: '使用指南', url: '/docs/faststart' };
}
