import type { Metadata } from 'next';
import { Provider } from '@/components/provider';
import './global.css';
import { SiteHeader } from '@/components/site-header';
export const metadata: Metadata = {
  title: { default: 'AppPorts 使用文档', template: '%s · AppPorts 文档' },
  description: '了解如何迁移应用与数据、使用外置存储，以及处理日常问题。',
  icons: { icon: '/logo.png' },
};
export default function Layout({ children }: { children: React.ReactNode }) {
  return <html lang="zh-Hans" suppressHydrationWarning><body><Provider><SiteHeader />{children}</Provider></body></html>;
}
