import { SiteDocument, siteMetadata } from '@/components/site-document';
import { isLocale } from '@/lib/i18n';
import { notFound } from 'next/navigation';
type Props = { children: React.ReactNode; params: Promise<{ lang: string }> };
export const dynamicParams = false;
export function generateStaticParams() { return [{ lang: 'zh-Hant' }, { lang: 'en' }]; }
export default async function Layout({ children, params }: Props) { const { lang } = await params; if (!isLocale(lang) || lang === 'zh-Hans') notFound(); return <SiteDocument locale={lang}>{children}</SiteDocument>; }
export async function generateMetadata({ params }: Props) { const { lang } = await params; if (!isLocale(lang)) notFound(); return siteMetadata(lang); }
