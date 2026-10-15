import { DocumentationPage, pageMetadata } from '@/components/docs-page';
import { source } from '@/lib/source';
import { isLocale } from '@/lib/i18n';
import { notFound } from 'next/navigation';
type Props = { params: Promise<{ lang: string; slug: string[] }> };
export const dynamicParams = false;
export function generateStaticParams({ params }: { params: { lang: string } }) { return source.getPages(params.lang).map(page => ({ slug: page.slugs })); }
export default async function Page({ params }: Props) { const { lang, slug } = await params; if (!isLocale(lang)) notFound(); return <DocumentationPage locale={lang} slug={slug} />; }
export async function generateMetadata({ params }: Props) { const { lang, slug } = await params; if (!isLocale(lang)) notFound(); return pageMetadata(slug, lang); }
