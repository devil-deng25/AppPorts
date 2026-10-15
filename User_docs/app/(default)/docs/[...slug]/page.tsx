import { DocumentationPage, pageMetadata } from '@/components/docs-page';
import { source } from '@/lib/source';
type Props = { params: Promise<{ slug: string[] }> };
export const dynamicParams = false;
export function generateStaticParams() { return source.getPages('zh-Hans').map(page => ({ slug: page.slugs })); }
export default async function Page({ params }: Props) { return <DocumentationPage locale="zh-Hans" slug={(await params).slug} />; }
export async function generateMetadata({ params }: Props) { return pageMetadata((await params).slug, 'zh-Hans'); }
