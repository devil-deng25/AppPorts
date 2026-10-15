'use client';
import { useState, type ComponentProps } from 'react';
export function DocsImage({ src, alt, width: _width, height: _height, ...props }: ComponentProps<'img'>) {
  const [failed, setFailed] = useState(false);
  if (failed) return <span className="image-unavailable" role="status">{alt || '演示图片'}暂时无法加载</span>;
  return <img {...props} src={src} alt={alt || '操作演示'} className="docs-image" loading="lazy" onError={() => setFailed(true)} />;
}
