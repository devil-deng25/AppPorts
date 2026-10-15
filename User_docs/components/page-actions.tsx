'use client';
import { useText } from './provider';
import { ChevronDown, FileText } from 'lucide-react';
import { GitHubIcon } from './github-icon';
import { MarkdownCopyButton } from 'fumadocs-ui/layouts/docs/page';
import { Popover, PopoverContent, PopoverTrigger } from 'fumadocs-ui/components/ui/popover';
export function PageActions({ markdownUrl, sourcePath }: { markdownUrl: string; sourcePath: string }) {
  const t = useText();
  return <div className="page-actions"><MarkdownCopyButton markdownUrl={markdownUrl} />
    <Popover><PopoverTrigger className="page-open-button">{t('打开')} <ChevronDown size={15} /></PopoverTrigger><PopoverContent className="page-open-menu">
      <a href={markdownUrl} target="_blank" rel="noreferrer"><FileText size={16} />{t('查看 Markdown')}</a>
      <a href={`https://github.com/wzh4869/AppPorts/blob/main/User_docs/docs/${sourcePath}`} target="_blank" rel="noreferrer"><GitHubIcon size={16} />{t('在 GitHub 中打开')}</a>
    </PopoverContent></Popover>
  </div>;
}
