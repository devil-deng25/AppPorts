import { SiteDocument, siteMetadata } from '@/components/site-document';
export const metadata = siteMetadata('zh-Hans');
export default function Layout({ children }: { children: React.ReactNode }) { return <SiteDocument locale="zh-Hans">{children}</SiteDocument>; }
