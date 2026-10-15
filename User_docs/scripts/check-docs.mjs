import assert from 'node:assert/strict';
import { readFile, access } from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { resolveLegacyLink } from '../lib/legacy-links.mjs';
import { convert } from './prepare-fumadocs.mjs';

const root = path.resolve(import.meta.dirname, '..');
const out = path.join(root, 'out');
const pages = JSON.parse(await readFile(path.join(root, '.content/manifest.json'), 'utf8'));
const existing = async file => { try { await access(file); return true; } catch { return false; } };
const htmlFiles = ['index.html', ...pages.map(page => `docs/${page.slug}.html`)];
const legacy = JSON.parse(await readFile(path.join(root, 'config/legacy-links.json'), 'utf8'));
const navigation = JSON.parse(await readFile(path.join(root, 'config/docs-navigation.json'), 'utf8'));
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
// Every old chapter must either still exist or resolve to an existing canonical section.
async function assertTarget(target) {
  const url = new URL(target, 'https://docs.test');
  const body = await html(path.join(out, url.pathname + '.html'));
  if (url.hash) assert.ok(body.includes(`id="${decodeURIComponent(url.hash.slice(1))}"`), `Missing compatibility target: ${target}`);
}
for (const [slug, anchors] of Object.entries(legacy.anchors)) {
  const body = await html(path.join(out, 'docs', slug + '.html'));
  for (const [old, current] of Object.entries(anchors)) {
    assert.ok(body.includes(`id="${old}"`), `Lost old heading: ${slug}#${old}`);
    assert.ok(body.includes(`id="${current}"`), `Missing new heading: ${slug}#${current}`);
    if (old !== current) {
      const afterAlias = body.slice(body.indexOf(`id="${old}"`));
      const nextHeading = afterAlias.match(/<h[2-6]\b[^>]*\bid="([^"]+)"/);
      assert.equal(nextHeading?.[1], current, `Old anchor lands in wrong chapter: ${slug}#${old}`);
    }
  }
}
for (const [slug, route] of Object.entries(legacy.routes)) {
  assert.ok(!pages.some(page => page.slug === slug), `Alias leaked into content/search: ${slug}`);
  const alias = await html(path.join(out, 'docs', slug + '.html'));
  assert.ok(alias.includes('noindex'), `Merged page must not be indexed: ${slug}`);
  const legacyHTML = await html(path.join(out, slug + '.html'));
  const script = legacyHTML.match(/<script>([\s\S]*?)<\/script>/)?.[1];
  assert.ok(script, `Missing legacy script: ${slug}`);
  for (const [anchor, target] of [['', route.target], ...Object.entries(route.anchors)]) {
    await assertTarget(target);
    let actual;
    vm.runInNewContext(script, { location: { search: '?from=old-help', hash: anchor ? '#' + encodeURIComponent(anchor) : '', replace: url => { actual = url; } } });
    assert.equal(actual, resolveLegacyLink(route, '?from=old-help', anchor ? '#' + encodeURIComponent(anchor) : ''));
    assert.ok(actual.includes('?from=old-help'), `Lost query: ${slug}`);
  }
}
assert.equal(resolveLegacyLink(legacy.routes['why-apfs'], '?source=app', '#prepare-apfs'), '/docs/storage-guide?source=app#prepare-apfs');
assert.equal(resolveLegacyLink(legacy.routes['why-apfs'], '', '#encrypted-drives'), '/docs/storage-guide#encrypted-drives');
assert.equal(resolveLegacyLink(legacy.routes.logging, '', '#%E0%A4'), '/docs/faq#feedback');
assert.equal(navigation.main[0].slug, 'AppPorts');
assert.equal(navigation.main.at(-1).slug, 'glossary');
assert.deepEqual(navigation.main.filter(entry => entry.children).map(entry => entry.name), ['原理', '博客', '帮助与支持', '历史功能归档']);
for (const slug of ['settings', 'changelog', 'sponsor', 'licenses', 'privacy']) assert.ok(navigation.main.some(entry => entry.slug === slug));
assert.equal(navigation.main.flatMap(entry => entry.children ?? [entry]).length, 26);
for (const slug of pages.map(page => page.slug).filter(slug => slug.startsWith('archive/'))) {
  const body = await readFile(path.join(root, 'docs', slug + '.md'), 'utf8');
  assert.match(body, /归档/);
  assert.match(body, /当前/);
}

for (const slug of ['research/sandbox-symlink', 'research/sandbox-mountpoint', 'research/unplug-test', 'research/prelogin-mount', 'research/container-structure', 'research/data-integrity']) {
  assert.ok(legacy.routes[slug]?.target.startsWith('/docs/blog/'), `Experiment missing blog destination: ${slug}`);
  assert.ok(!pages.some(page => page.slug === slug), `Retired experiment still independently indexed: ${slug}`);
}
assert.equal(navigation.main.at(-1).name, '名词解释');
assert.equal(navigation.main.find(entry => entry.name === '历史功能归档')?.children.length, 4);

const aliasFixture = convert('# Title\n\n## New title {#new}\n\nBody', { old: 'new' });
assert.match(aliasFixture.body, /id="old"/);
assert.throws(() => convert('# Title', { old: 'missing' }), /Legacy anchor target does not exist/);
const topicLinks = JSON.parse(await readFile(path.join(root, 'config/language-links.json'), 'utf8'));
const languages = JSON.parse(await readFile(path.join(root, '.content/languages.json'), 'utf8'));
for (const language of languages) {
  for (const [topic, candidates] of Object.entries(topicLinks)) {
    const target = candidates.find(candidate => language.pages.includes(candidate.slug));
    if (['restore', 'classic-mode', 'principles/macos-27'].includes(topic)) assert.ok(target, `Missing related translation: ${topic}/${language.lang}`);
    if (target?.anchor) {
      const translation = await readFile(path.join(root, 'docs', language.lang, target.slug + '.md'), 'utf8');
      assert.ok(translation.includes(`{#${target.anchor}}`), `Missing translated anchor: ${topic}/${language.lang}`);
    }
  }
}
const intro = await html(path.join(out, 'docs/AppPorts.html'));
for (const url of ['https://deepwiki.com/wzh4869/AppPorts', 'https://www.shimoko.com/p/appports/']) assert.ok(intro.includes(`href="${url}"`));
assert.throws(() => convert('# Title\n\n## One {#one}\n\n## Two {#two}', { one: 'two' }), /Legacy anchor collision/);
assert.deepEqual(JSON.parse(await readFile(path.join(out, 'sponsors.json'))), JSON.parse(await readFile(path.join(root, '../sponsors.json'))));
assert.deepEqual(JSON.parse(await readFile(path.join(out, 'latest.json'))), JSON.parse(await readFile(path.join(root, 'docs/public/latest.json'))));
const sample = convert('# Test\n\n::: warning Important\n\nKeep {literal} and <path>.\n\n```sh\necho ":::"\n```\n\n:::\n\n::: details More\n\n[Link](/faststart.html#下载)\n\n:::\n');
assert.match(sample.body, /<Callout type="warning" title="Important">/);
assert.match(sample.body, /<details>/);
assert.match(sample.body, /\/docs\/faststart#下载/);
assert.match(sample.body, /echo ":::"/);
assert.throws(() => convert('::: warning Oops\n\ntext'), /Unclosed/);
assert.equal(failures.length, 0, failures.join('\n'));
console.log(`Verified ${pages.length} pages, internal links and anchors, ${Object.keys(legacy.routes).length} merged routes and their former chapters, archive/navigation contracts, conversion guards, and both JSON endpoints.`);
