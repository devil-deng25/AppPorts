import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const pages = JSON.parse(await readFile(path.join(root, '.content/manifest.json'), 'utf8'));
for (const { slug } of pages) {
  const target = '/docs/' + slug;
  const html = `<!doctype html><html lang="zh-Hans"><meta charset="utf-8"><meta name="robots" content="noindex"><link rel="canonical" href="${target}"><meta http-equiv="refresh" content="0;url=${target}"><title>正在打开 AppPorts 文档</title><script>location.replace(${JSON.stringify(target)}+location.search+location.hash)</script><p><a href="${target}">打开文档</a></p></html>`;
  const file = path.join(root, 'out', slug + '.html');
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, html);
}
console.log(`Exported ${pages.length} legacy .html paths.`);
