/**
 * Resolve a merged page once, including its former chapter links.
 * @param {{ target: string, anchors: Record<string, string> }} route
 * @param {string} search
 * @param {string} hash
 */
export function resolveLegacyLink(route, search = '', hash = '') {
  let anchor;
  try { anchor = decodeURIComponent(hash.replace(/^#/, '')); } catch { anchor = ''; }
  const target = Object.hasOwn(route.anchors, anchor) ? route.anchors[anchor] : route.target;
  const [pathname, section] = target.split('#');
  return pathname + search + (section ? '#' + section : '');
}
