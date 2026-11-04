/**
 * Prefixes a site path with the configured `base` (see astro.config.mjs), so links work on
 * GitHub Pages project sites (/joobq/...) and at a domain root alike. Anchors ("#x"),
 * absolute URLs and mailto: links pass through unchanged.
 */
export function url(path: string): string {
  if (/^(https?:|mailto:|#)/.test(path)) return path;
  const base = import.meta.env.BASE_URL.replace(/\/$/, '');
  const clean = path.startsWith('/') ? path : `/${path}`;
  return `${base}${clean}` || '/';
}

/** Landing-page anchors ("#pricing") become "/#pricing" when used away from the landing page. */
export function navHref(href: string, onLanding: boolean): string {
  if (href.startsWith('#') && !onLanding) return url(`/${href}`);
  return url(href);
}
