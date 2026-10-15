'use client';
import { useLocale } from './provider';
import sponsors from '@/public/sponsors.json';
export function SponsorList() {
  const locale = useLocale();
  const entries = [...sponsors.sponsors].sort((a, b) => b.amount - a.amount || new Date(a.date).getTime() - new Date(b.date).getTime());
  return <div className="sponsor-list not-prose">{entries.map(sponsor => <div key={sponsor.name}>{sponsor.link ? <a href={sponsor.link} target="_blank" rel="noreferrer">{sponsor.name}</a> : <span>{sponsor.name}</span>}<span>¥{sponsor.amount.toLocaleString(locale, { maximumFractionDigits: 2 })}</span></div>)}</div>;
}
