import { readFile, writeFile, mkdir, rm, readdir, cp } from 'node:fs/promises';
import path from 'node:path';
import matter from 'gray-matter';
import { unified } from 'unified';
import remarkParse from 'remark-parse';
import remarkStringify from 'remark-stringify';
import remarkGfm from 'remark-gfm';
import remarkMdx from 'remark-mdx';
import { visit } from 'unist-util-visit';

const root = path.resolve(import.meta.dirname, '..');
const input = path.join(root, 'docs');
const output = path.join(root, '.content/docs');
const parser = unified().use(remarkParse).use(remarkGfm);
const writer = unified().use(remarkStringify).use(remarkGfm).use(remarkMdx);
const locales = new Set(['en', 'de', 'es', 'fr', 'ja', 'ko', 'zh-Hant']);
export const navigation = {
  '': { title: 'AppPorts 文档', pages: ['---指南---', 'AppPorts', 'faststart', 'core', 'badges', 'datamigrae', 'migration-strategy', 'settings', 'storage-guide', 'why-apfs', 'macos-27', 'limitations', 'troubleshooting', 'faq', 'logging', 'research', 'changelog', 'sponsor', 'contributing', 'licenses', 'privacy'] },
  datamigrae: { title: '数据迁移', pages: ['baseinfo', 'tools', 'operation', 'mount-migration', 'resign', 'container-identity'] },
  'migration-strategy': { title: 'App 迁移策略', pages: ['portal', 'strategy-map', 'updater-detection', 'appstore-update'] },
  research: { title: '实验记录', pages: ['sandbox-symlink', 'sandbox-mountpoint', 'unplug-test', 'prelogin-mount'] },
};
function jsx(name, props = {}, children = []) {
  return { type: 'mdxJsxFlowElement', name, attributes: Object.entries(props).map(([name, value]) => ({ type: 'mdxJsxAttribute', name, value })), children };
}
function textOf(node) { return node.value ?? node.children?.map(textOf).join('') ?? ''; }
function spaceContainers(content) {
  let fence;
  return content.split('\n').map(line => {
    const marker = line.match(/^\s*(`{3,}|~{3,})/);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length) fence = undefined;
    }
    return !fence && /^:::(?:\s|$)/.test(line) ? `\n${line}\n` : line;
  }).join('\n');
}
export function portableMarkdown(tree, sponsorData) {
  function convertNode(node) {
    const children = node.children?.flatMap(convertNode);
    if (node.type !== 'mdxJsxFlowElement') return [{ ...node, ...(children ? { children } : {}) }];
    const attrs = Object.fromEntries(node.attributes.map(attr => [attr.name, attr.value]));
    const paragraph = text => ({ type: 'paragraph', children: [{ type: 'strong', children: [{ type: 'text', value: text }] }] });
    if (node.name === 'Callout') return [{ type: 'blockquote', children: [paragraph(attrs.title), ...children] }];
    if (node.name === 'details') return [{ type: 'blockquote', children }];
    if (node.name === 'summary') return [{ type: 'paragraph', children: [{ type: 'strong', children }] }];
    if (node.name === 'Mermaid') return [{ type: 'code', lang: 'mermaid', value: attrs.chart }];
    if (node.name === 'span') return [];
    if (node.name === 'SponsorList') {
      const cell = children => ({ type: 'tableCell', children });
      const text = value => ({ type: 'text', value });
      const row = cells => ({ type: 'tableRow', children: cells });
      const sponsors = [...sponsorData.sponsors].sort((a,b) => b.amount-a.amount || new Date(a.date)-new Date(b.date));
      return [{ type: 'table', align: [null, 'right'], children: [
        row([cell([text('赞助者')]), cell([text('金额（CNY）')])]),
        ...sponsors.map(sponsor => row([
          cell([sponsor.link ? { type: 'link', url: sponsor.link, children: [text(sponsor.name)] } : text(sponsor.name)]),
          cell([text(sponsor.amount.toLocaleString('zh-CN', { maximumFractionDigits: 2 }))]),
        ])),
      ] }];
    }
    throw new Error(`Unsupported Markdown export component: ${node.name}`);
  }
  return unified().use(remarkStringify).use(remarkGfm).stringify(convertNode(tree)[0]);
}
export function convert(content) {
  content = content.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '')
    .replace(/<div align="center">\s*<img src="([^"]+)" alt="([^"]*)"[^>]*\/>\s*<\/div>/g, '![$2]($1)');
  const tree = parser.parse(spaceContainers(content));
  const result = { type: 'root', children: [] };
  const stack = [result];
  for (const node of tree.children) {
    const marker = node.type === 'paragraph' ? textOf(node).match(/^:::(?:\s+(tip|info|warning|danger|details)(?:\s+(.*))?)?$/) : null;
    if (marker) {
      if (!marker[1]) {
        if (stack.length === 1) throw new Error('Unexpected closing VitePress container');
        stack.pop();
      } else {
        const [, kind, title] = marker;
        const block = kind === 'details'
          ? jsx('details', {}, [jsx('summary', {}, [{ type: 'text', value: title || '详细说明' }])])
          : jsx('Callout', { type: ({ tip: 'info', danger: 'error' })[kind] || kind, title: title || ({ tip: '提示', info: '说明', warning: '注意', danger: '警告' })[kind] });
        stack.at(-1).children.push(block); stack.push(block);
      }
    } else if (node.type === 'html' && /^<SponsorList\b/.test(node.value)) {
      stack.at(-1).children.push(jsx('SponsorList'));
    } else if (node.type === 'html') {
      throw new Error(`Unsupported HTML: ${node.value.slice(0, 100)}`);
    } else {
      stack.at(-1).children.push(node);
    }
  }
  if (stack.length !== 1) throw new Error('Unclosed VitePress container');
  visit(result, 'heading', (node, index, parent) => {
    const last = node.children.at(-1);
    const anchor = last?.type === 'text' && last.value.match(/\s*\{#([^}]+)\}\s*$/);
    if (anchor) {
      last.value = last.value.slice(0, anchor.index);
      parent.children.splice(index, 0, jsx('span', { id: anchor[1] }));
      return index + 2;
    }
  });
  visit(result, 'link', node => {
    const [url, hash] = node.url.split('#');
    if (!url || /^(?:[a-z]+:|\/\/)/i.test(url)) return;
    if (url.startsWith('/docs/')) return;
    if (url.startsWith('/')) node.url = '/docs' + url.replace(/\.(?:md|html)$/, '') + (hash ? '#' + hash : '');
    else node.url = url.replace(/\.md$/, '') + (hash ? '#' + hash : '');
  });
  visit(result, 'code', (node, index, parent) => {
    if (node.lang === 'mermaid') parent.children[index] = jsx('Mermaid', { chart: node.value });
  });
  const firstHeading = result.children.findIndex(node => node.type === 'heading' && node.depth === 1);
  let title;
  if (firstHeading !== -1) title = textOf(result.children.splice(firstHeading, 1)[0]);
  return { title, body: writer.stringify(result), tree: result };
}
async function walk(dir, prefix = '') {
  const files = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.') || locales.has(entry.name) || entry.name === 'public') continue;
    const relative = path.join(prefix, entry.name);
    if (entry.isDirectory()) files.push(...await walk(path.join(dir, entry.name), relative));
    else if (entry.name.endsWith('.md') && relative !== 'index.md') files.push(relative);
  }
  return files.sort();
}
if (process.argv[1] === import.meta.filename) {
  await rm(path.join(root, '.content'), { recursive: true, force: true });
  await mkdir(output, { recursive: true });
  const manifest = [];
  const sponsors = JSON.parse(await readFile(path.join(root, '../sponsors.json'), 'utf8'));
  await rm(path.join(root, 'public/docs-md'), { recursive: true, force: true });
  for (const file of await walk(input)) {
    const { content, data } = matter(await readFile(path.join(input, file), 'utf8'));
    const { title, body, tree } = convert(content);
    const slug = file.replace(/\.md$/, '');
    const target = path.join(output, slug + '.mdx');
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, matter.stringify(body, { title: data.title || title || slug, sourcePath: file }));
    const markdownPath = path.join(root, 'public/docs-md', slug + '.md');
    await mkdir(path.dirname(markdownPath), { recursive: true });
    await writeFile(markdownPath, '# ' + (data.title || title || slug) + '\n\n' + portableMarkdown(tree, sponsors));
    manifest.push({ slug, sourcePath: file, title: data.title || title || slug });
  }
  for (const [folder, meta] of Object.entries(navigation)) {
    await mkdir(path.join(output, folder), { recursive: true });
    await writeFile(path.join(output, folder, 'meta.json'), JSON.stringify(meta, null, 2));
  }
  await writeFile(path.join(root, '.content/manifest.json'), JSON.stringify(manifest, null, 2));
  await mkdir(path.join(root, 'public'), { recursive: true });
  await cp(path.join(input, 'public'), path.join(root, 'public'), { recursive: true });
  await cp(path.join(root, '../sponsors.json'), path.join(root, 'public/sponsors.json'));
  console.log(`Prepared ${manifest.length} Chinese pages and public assets.`);
}
