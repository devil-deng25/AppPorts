'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useEffect, useState } from 'react';
import { Check, Languages } from 'lucide-react';
import { Popover, PopoverContent, PopoverTrigger } from 'fumadocs-ui/components/ui/popover';
import { locales, languageNames, localePrefix, docUrl, homeUrl, type Locale } from '@/lib/i18n';
import { useLocale, useText } from './provider';
export function LanguageSwitch() {
  const pathname = usePathname();
  const current = useLocale(); const t = useText();
  const [open, setOpen] = useState(false);
  const [hash, setHash] = useState('');
  useEffect(() => {
    const update = () => setHash(window.location.hash);
    update();
    window.addEventListener('hashchange', update);
    return () => window.removeEventListener('hashchange', update);
  }, [pathname]);
  const path = pathname.slice(localePrefix(current).length);
  const slug = path.startsWith('/docs/') ? path.slice(6) : undefined;
  function href(locale: Locale) { return slug ? docUrl(locale, slug) + hash : homeUrl(locale); }
  return <Popover open={open} onOpenChange={value => { if (value) setHash(window.location.hash); setOpen(value); }}>
    <PopoverTrigger className="header-language-trigger" aria-label={t('切换语言')} title={t('切换语言')}><Languages size={18} /></PopoverTrigger>
    <PopoverContent className="header-language-menu" aria-label={t('选择文档语言')}>
      {locales.map(locale => <Link key={locale} lang={locale} hrefLang={locale} href={href(locale)} aria-current={locale === current ? 'true' : undefined}
        onClick={() => setOpen(false)}>
        {languageNames[locale]}{locale === current && <Check size={15} />}
      </Link>)}
    </PopoverContent>
  </Popover>;
}
