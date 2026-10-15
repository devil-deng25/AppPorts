import { DocumentationLayout } from '@/components/docs-layout';
import { isLocale } from '@/lib/i18n';
import { notFound } from 'next/navigation';
export default async function Layout({ children, params }: { children: React.ReactNode; params: Promise<{ lang: string }> }) { const { lang } = await params; if (!isLocale(lang)) notFound(); return <DocumentationLayout locale={lang}>{children}</DocumentationLayout>; }
