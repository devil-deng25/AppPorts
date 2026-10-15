import { docsTree } from '@/lib/navigation';
import { DocsLayout } from 'fumadocs-ui/layouts/docs';
import { text, homeUrl, type Locale } from '@/lib/i18n';
export function DocumentationLayout({ children, locale }: { children: React.ReactNode; locale: Locale }) {
  return <DocsLayout tree={docsTree(locale)} nav={{ title: text(locale, '文档目录'), url: homeUrl(locale) }} themeSwitch={{ enabled: false }}>{children}</DocsLayout>;
}
