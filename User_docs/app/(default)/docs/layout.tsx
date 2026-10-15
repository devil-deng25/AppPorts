import { DocumentationLayout } from '@/components/docs-layout';
export default function Layout({ children }: { children: React.ReactNode }) { return <DocumentationLayout locale="zh-Hans">{children}</DocumentationLayout>; }
