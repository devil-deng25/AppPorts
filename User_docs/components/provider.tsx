'use client';
import SearchDialog from '@/components/search';
import { RootProvider } from 'fumadocs-ui/provider/next';
import { createContext, useContext, type ReactNode } from 'react';
import catalogs from '@/config/locales.json';
import { text, type Locale } from '@/lib/i18n';
const LocaleContext = createContext<Locale>('zh-Hans');
export function useLocale() { return useContext(LocaleContext); }
export function useText() { const locale = useLocale(); return (key: string) => text(locale, key); }
export function Provider({ children, locale }: { children: ReactNode; locale: Locale }) {
  return <LocaleContext.Provider value={locale}><RootProvider search={{ SearchDialog }} i18n={{ locale, translations: catalogs[locale].provider }}>{children}</RootProvider></LocaleContext.Provider>;
}
