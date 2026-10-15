'use client';
import { usePathname } from 'next/navigation';
import { useState } from 'react';
import { Check, Languages } from 'lucide-react';
import { Popover, PopoverContent, PopoverTrigger } from 'fumadocs-ui/components/ui/popover';
import languages from '@/.content/languages.json';

export function LanguageSwitch() {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const slug = pathname.replace(/^\/docs\/?/, '').replace(/\/$/, '');
  return <Popover open={open} onOpenChange={setOpen}>
    <PopoverTrigger className="header-language-trigger" aria-label="切换语言" title="切换语言">
      <Languages size={18} />
    </PopoverTrigger>
    <PopoverContent className="header-language-menu" aria-label="选择文档语言">
      <button type="button" lang="zh-Hans" aria-current="true" onClick={() => setOpen(false)}>
        简体中文 <Check size={15} />
      </button>
      {languages.map(({ lang, label, pages }) => <a key={lang} lang={lang} hrefLang={lang}
        href={`https://docs-appports.shimoko.com/${lang}/${pathname.startsWith('/docs/') && pages.includes(slug) ? slug + '.html' : ''}`}
        onClick={() => setOpen(false)}>{label}</a>)}
    </PopoverContent>
  </Popover>;
}
