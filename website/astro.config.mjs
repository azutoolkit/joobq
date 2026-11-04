import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';

// Deployment target. GitHub Pages project sites live under /<repo>, so set
// BASE_PATH=/joobq there; Cloudflare Pages and Netlify serve from the root.
const site = process.env.SITE_URL ?? 'https://azutoolkit.github.io';
const base = process.env.BASE_PATH ?? '/';

// Docs pages link to each other as "/docs/...": prefix those links with the base path.
function rehypeBaseLinks() {
  const prefix = base.replace(/\/$/, '');
  const walk = (node) => {
    if (node.type === 'element' && node.tagName === 'a') {
      const href = node.properties?.href;
      if (typeof href === 'string' && href.startsWith('/') && !href.startsWith('//')) {
        node.properties.href = `${prefix}${href}`;
      }
    }
    node.children?.forEach(walk);
  };
  return (tree) => walk(tree);
}

export default defineConfig({
  site,
  base,
  output: 'static',
  trailingSlash: 'ignore',
  markdown: {
    rehypePlugins: [rehypeBaseLinks],
    shikiConfig: {
      theme: 'github-dark-default',
      wrap: false,
    },
  },
  vite: {
    plugins: [tailwindcss()],
  },
});
