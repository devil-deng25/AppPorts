import assert from 'node:assert/strict';
import { readFile, access } from 'node:fs/promises';
import path from 'node:path';
import { convert } from './prepare-fumadocs.mjs';

const root = path.resolve(import.meta.dirname, '..');
const out = path.join(root, 'out');
const pages = JSON.parse(await readFile(path.join(root, '.content/manifest.json'), 'utf8'));
const existing = async file => { try { await access(file); return true; } catch { return false; } };
const htmlFiles = ['index.html', ...pages.map(page => `docs/${page.slug}.html`)];
const failures = [];
const cache = new Map();
async function html(file) {
  if (!cache.has(file)) cache.set(file, await readFile(file, 'utf8'));
  return cache.get(file);
}
for (const file of htmlFiles) {
  const body = await html(path.join(out, file));
  assert.ok(!body.includes('::: tip') && !body.includes('::: warning'), `Unconverted callout in ${file}`);
  const current = new URL('/' + file.replace(/index\.html$/, '').replace(/\.html$/, ''), 'https://docs.test');
  for (const [, raw] of body.matchAll(/<(?:a|link)\b[^>]*\bhref="([^"]+)"/g)) {
    if (/^(?:mailto:|tel:|data:)/.test(raw)) continue;
    const target = new URL(raw.replaceAll('&amp;', '&'), current);
    if (target.origin !== current.origin) continue;
    const pathname = decodeURIComponent(target.pathname).replace(/^\//, '');
    const candidates = pathname ? [path.join(out, pathname), path.join(out, pathname + '.html'), path.join(out, pathname, 'index.html')] : [path.join(out, 'index.html')];
    let destination;
    for (const candidate of candidates) if (await existing(candidate)) { destination = candidate; break; }
    if (!destination) { failures.push(`${file}: missing ${raw}`); continue; }
    if (target.hash && destination.endsWith('.html')) {
      const id = decodeURIComponent(target.hash.slice(1));
      const targetHTML = await html(destination);
      if (!targetHTML.includes(`id="${id}"`)) failures.push(`${file}: missing anchor ${raw}`);
    }
  }
}
for (const page of pages) {
  const markdown = await readFile(path.join(out, 'docs-md', page.slug + '.md'), 'utf8');
  assert.ok(!/<(?:SponsorList|Mermaid|Callout)\b/.test(markdown), `Non-portable MDX component: ${page.slug}`);
  if (page.slug === 'sponsor') assert.ok(markdown.includes('师杀') && markdown.includes('350') && markdown.includes('0.63'), 'Sponsor content missing from Markdown');
  if (page.slug === 'migration-strategy/portal') assert.ok(markdown.includes('```mermaid'), 'Mermaid source missing from Markdown');
  assert.ok(markdown.startsWith('# ' + page.title), `Missing Markdown source: ${page.slug}`);
  const source = await readFile(path.join(root, 'docs', page.sourcePath), 'utf8');
  const rendered = await html(path.join(out, 'docs', page.slug + '.html'));
  for (const [, id] of source.matchAll(/\{#([^}]+)\}/g)) assert.ok(rendered.includes(`id="${id}"`), `Missing explicit anchor: ${page.slug}#${id}`);
  const legacy = await html(path.join(out, `${page.slug}.html`));
  assert.ok(legacy.includes(`/docs/${page.slug}`) && legacy.includes('location.hash'), `Legacy URL loses target/hash: ${page.slug}`);
}
assert.deepEqual(JSON.parse(await readFile(path.join(out, 'sponsors.json'))), JSON.parse(await readFile(path.join(root, '../sponsors.json'))));
assert.deepEqual(JSON.parse(await readFile(path.join(out, 'latest.json'))), JSON.parse(await readFile(path.join(root, 'docs/public/latest.json'))));
const sample = convert('# Test\n\n::: warning Important\n\nKeep {literal} and <path>.\n\n```sh\necho ":::"\n```\n\n:::\n\n::: details More\n\n[Link](/faststart.html#下载)\n\n:::\n');
assert.match(sample.body, /<Callout type="warning" title="Important">/);
assert.match(sample.body, /<details>/);
assert.match(sample.body, /\/docs\/faststart#下载/);
assert.match(sample.body, /echo ":::"/);
assert.throws(() => convert('::: warning Oops\n\ntext'), /Unclosed/);
assert.equal(failures.length, 0, failures.join('\n'));
console.log(`Verified ${pages.length} pages, internal links and anchors, legacy URLs, conversion guards, and both JSON endpoints.`);
