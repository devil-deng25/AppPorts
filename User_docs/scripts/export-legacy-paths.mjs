import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { resolveLegacyLink } from '../lib/legacy-links.mjs';
const root = path.resolve(import.meta.dirname, '..');
const pages = JSON.parse(await readFile(path.join(root, '.content/manifest.json'), 'utf8'));
const { routes } = JSON.parse(await readFile(path.join(root, 'config/legacy-links.json'), 'utf8'));
const all = new Set([...pages.map(page => page.slug), ...Object.keys(routes)]);
for (const slug of all) {
  const target = routes[slug]?.target ?? '/docs/' + slug;
  const script = routes[slug]
    ? `location.replace((${resolveLegacyLink.toString()})(${JSON.stringify(routes[slug])},location.search,location.hash))`
    : `location.replace(${JSON.stringify(target)}+location.search+location.hash)`;
  const html = `<!doctype html><html lang="zh-Hans"><meta charset="utf-8"><meta name="robots" content="noindex"><link rel="canonical" href="${target.split('#')[0]}"><title>正在打开 AppPorts 文档</title><script>${script}</script><p><a href="${target}">打开文档</a></p></html>`;
  const file = path.join(root, 'out', slug + '.html');
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, html);
}
console.log(`Exported ${all.size} legacy .html paths (${Object.keys(routes).length} merged pages).`);
