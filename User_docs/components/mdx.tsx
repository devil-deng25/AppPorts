import defaultMdxComponents from 'fumadocs-ui/mdx';
import type { MDXComponents } from 'mdx/types';
import { Callout } from 'fumadocs-ui/components/callout';
import { Mermaid } from './mermaid';
import { SponsorList } from './sponsors';
import { DocsImage } from './docs-image';
export function getMDXComponents(components?: MDXComponents) {
  return { ...defaultMdxComponents, img: DocsImage, Callout, Mermaid, SponsorList, ...components } satisfies MDXComponents;
}
export const useMDXComponents = getMDXComponents;
declare global { type MDXProvidedComponents = ReturnType<typeof getMDXComponents>; }
