import { source } from '@/lib/source';
import Link from 'next/link';
import { PageActions } from '@/components/page-actions';
import { descriptions } from '@/lib/descriptions';
import { pageSection } from '@/lib/navigation';
import { DocsBody, DocsDescription, DocsPage, DocsTitle } from 'fumadocs-ui/layouts/docs/page';
import { notFound, redirect } from 'next/navigation';
import { getMDXComponents } from '@/components/mdx';
import { createRelativeLink } from 'fumadocs-ui/mdx';

type Props = { params: Promise<{ slug?: string[] }> };
export default async function Page({ params }: Props) {
  const { slug } = await params;
  if (!slug?.length) redirect('/docs/faststart');
  const page = source.getPage(slug);
  if (!page) notFound();
  const MDX = page.data.body;
  const slugPath = slug.join('/');
  const section = pageSection(page.url);
  return <DocsPage breadcrumb={{ enabled: false }} toc={page.data.toc} tableOfContent={{ style: 'clerk' }}>
    <Link className="page-section" href={section.url}>{section.name}</Link>
    <DocsTitle>{page.data.title}</DocsTitle>
    <DocsDescription>{descriptions[slugPath]}</DocsDescription>
    <PageActions markdownUrl={`/docs-md/${slugPath}.md`} sourcePath={`${slugPath}.md`} />
    <DocsBody><MDX components={getMDXComponents({ a: createRelativeLink(source, page) })} /></DocsBody>
  </DocsPage>;
}
export function generateStaticParams() { return [{ slug: [] }, ...source.generateParams()]; }
export async function generateMetadata({ params }: Props) {
  const { slug } = await params;
  return { title: source.getPage(slug)?.data.title || '使用指南' };
}
