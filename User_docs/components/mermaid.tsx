'use client';
import { useEffect, useId, useState } from 'react';
import { useTheme } from 'next-themes';
export function Mermaid({ chart }: { chart: string }) {
  const id = useId().replace(/:/g, '');
  const { resolvedTheme } = useTheme();
  const [svg, setSvg] = useState('');
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let cancelled = false;
    setSvg(''); setFailed(false);
    import('mermaid').then(async ({ default: mermaid }) => {
      mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: resolvedTheme === 'dark' ? 'dark' : 'default', fontFamily: 'system-ui' });
      const { svg } = await mermaid.render(`diagram-${id}`, chart);
      if (!cancelled) setSvg(svg);
    }).catch(() => { if (!cancelled) setFailed(true); });
    return () => { cancelled = true; };
  }, [chart, id, resolvedTheme]);
  if (!svg) return <pre aria-label={failed ? '图表源代码' : '正在加载图表'}>{chart}</pre>;
  return <div className="mermaid-diagram" role="img" aria-label="迁移流程图" dangerouslySetInnerHTML={{ __html: svg }} />;
}
