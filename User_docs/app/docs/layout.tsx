import { docsTree } from '@/lib/navigation';
import { DocsLayout } from 'fumadocs-ui/layouts/docs';
export default function Layout({ children }: { children: React.ReactNode }) {
  return <DocsLayout tree={docsTree()} nav={{ title: '文档目录' }} themeSwitch={{ enabled: false }}>{children}</DocsLayout>;
}
