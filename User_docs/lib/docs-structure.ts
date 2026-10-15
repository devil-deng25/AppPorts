import { text, docUrl, type Locale } from './i18n';
import type { Root, Node, Item } from 'fumadocs-core/page-tree';
import navigation from '@/config/docs-navigation.json';

type Entry = { name: string; icon: string; slug?: string; children?: Entry[] };
export const entries: Entry[] = navigation.main;

// The same tree supplies the sidebar, page classification and previous/next links.
export function applyDocsStructure(root: Root, locale: Locale): Root {
  const pages = new Map<string, Item>();
  function collect(nodes: Node[]) {
    for (const node of nodes) {
      if (node.type === 'page') pages.set(node.url, node);
      else if (node.type === 'folder') {
        if (node.index) pages.set(node.index.url, node.index);
        collect(node.children);
      }
    }
  }
  collect(root.children);
  function build(entry: Entry): Node {
    if (entry.children) return { type: 'folder', name: text(locale, entry.name), defaultOpen: false, children: entry.children.map(build) };
    const page = pages.get(docUrl(locale, entry.slug!));
    if (!page) throw new Error(`Missing navigation page: ${entry.slug}`);
    return { ...page, name: text(locale, entry.name) };
  }
  return { ...root, name: 'AppPorts', children: entries.map(build) };
}
