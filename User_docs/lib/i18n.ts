import catalogs from '@/config/locales.json';
export const locales = ['zh-Hans', 'zh-Hant', 'en'] as const;
export type Locale = (typeof locales)[number];
export function isLocale(value: string): value is Locale { return locales.includes(value as Locale); }
export const languageNames: Record<Locale, string> = { 'zh-Hans': '简体中文', 'zh-Hant': '繁體中文', en: 'English' };
export function localePrefix(locale: Locale) { return locale === 'zh-Hans' ? '' : `/${locale}`; }
export function homeUrl(locale: Locale) { return localePrefix(locale) || '/'; }
export function docUrl(locale: Locale, slug: string) { return `${localePrefix(locale)}/docs/${slug}`; }
export function text(locale: Locale, key: string): string { return (catalogs[locale].text as Record<string, string>)[key] ?? key; }
export function description(locale: Locale, slug: string): string { return (catalogs[locale].descriptions as Record<string, string>)[slug] ?? ''; }
export function localeFromPath(path: string): Locale {
  const first = path.split('/')[1];
  return first === 'en' || first === 'zh-Hant' ? first : 'zh-Hans';
}
export function alternates(slug?: string) {
  return { languages: Object.fromEntries(locales.map(locale => [locale, slug ? docUrl(locale, slug) : homeUrl(locale)])) };
}
