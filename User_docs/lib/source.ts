import { docUrl, isLocale } from './i18n';
import { applyDocsStructure } from './docs-structure';
import { loader } from 'fumadocs-core/source';
import { defineDocs } from 'fumadocs-mdx/macro';
import { metaSchema, pageSchema } from 'fumadocs-core/source/schema';

const docs = defineDocs({
  dir: '.content/docs',
  docs: { schema: pageSchema, postprocess: { includeProcessedMarkdown: true } },
  meta: { schema: metaSchema },
});
export const source = loader({
  baseUrl: '/docs', source: docs.toFumadocsSource(),
  i18n: { languages: ['zh-Hans', 'zh-Hant', 'en'], defaultLanguage: 'zh-Hans', parser: 'dir', fallbackLanguage: null },
  url: (slugs, locale) => docUrl(locale && isLocale(locale) ? locale : 'zh-Hans', slugs.join('/')),
  pageTree: { generateFallback: false, transformers: [{ root(root) { return applyDocsStructure(root, this.locale && isLocale(this.locale) ? this.locale : 'zh-Hans'); } }] },
});
