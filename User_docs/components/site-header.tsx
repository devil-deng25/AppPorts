'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useState } from 'react';
import { Heart, Menu } from 'lucide-react';
import { GitHubIcon } from './github-icon';
import { LanguageSwitch } from './language-switch';
import { SearchTrigger } from 'fumadocs-ui/layouts/shared/slots/search-trigger';
import { ThemeSwitch } from 'fumadocs-ui/layouts/shared/slots/theme-switch';
import { Popover, PopoverContent, PopoverTrigger } from 'fumadocs-ui/components/ui/popover';
const links = [
  { label: '文档', href: '/docs/AppPorts' },
  { label: '博客', href: '/docs/blog/overview' },
  { label: '更新日志', href: '/docs/changelog' },
  { label: '官网', href: 'https://appports.shimoko.com' },
  { label: '下载 AppPorts', href: 'https://file.shimoko.com/AppPorts' },
];
export function SiteHeader() {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const active = (href: string) => {
    if (href === '/docs/blog/overview') return pathname.startsWith('/docs/blog/');
    if (href === '/docs/AppPorts') return pathname.startsWith('/docs') && !pathname.startsWith('/docs/blog/') && !['/docs/changelog', '/docs/sponsor'].includes(pathname);
    return pathname === href;
  };
  return <header className="site-header"><div className="site-header-inner">
    <Link href="/" className="site-brand"><img src="/logo.png" width="28" height="28" alt="" /><span>AppPorts</span><span className="brand-divider">文档</span></Link>
    <nav className="desktop-nav" aria-label="顶部导航">{links.map(({ label, href }) => <Link key={href} href={href} aria-current={active(href) ? 'page' : undefined}>{label}</Link>)}</nav>
    <div className="header-actions"><Link href="/docs/sponsor" className="header-sponsor" aria-label="赞助"><Heart size={15} /><span>赞助</span></Link><SearchTrigger /><LanguageSwitch /><ThemeSwitch /><a href="https://github.com/wzh4869/AppPorts" aria-label="GitHub 仓库" className="header-github"><GitHubIcon size={20} /></a>
      <div className="mobile-site-menu"><Popover open={open} onOpenChange={setOpen}><PopoverTrigger className="header-menu-trigger" aria-label="打开全站菜单"><Menu size={20} /></PopoverTrigger><PopoverContent className="site-menu-content" aria-label="顶部导航">{links.map(({ label, href }) => <Link key={href} href={href} onClick={() => setOpen(false)}>{label}</Link>)}</PopoverContent></Popover></div>
    </div>
  </div></header>;
}
