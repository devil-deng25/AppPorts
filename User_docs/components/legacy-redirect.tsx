'use client';
import { useEffect } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { resolveLegacyLink } from '@/lib/legacy-links.mjs';

export function LegacyRedirect({ route }: { route: { target: string; anchors: Record<string, string> } }) {
  const router = useRouter();
  useEffect(() => { router.replace(resolveLegacyLink(route, window.location.search, window.location.hash)); }, [route, router]);
  return <main className="p-8"><p>这篇文档已合并到相关主题。</p><Link href={route.target}>打开文档</Link></main>;
}
