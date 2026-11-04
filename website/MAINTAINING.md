# Maintaining the website

Astro 5 + Tailwind CSS 4, fully static. Node 22 and pnpm.

```bash
cd website
pnpm install
pnpm dev       # http://localhost:4321
pnpm build     # astro check + static build into dist/
pnpm preview   # serve dist/
```

All copy lives in `src/data/` and `src/content/docs/`. Components (`src/components/`) only lay it out.

## 1. Add or edit a docs page (30 seconds)

Create `src/content/docs/<section>/<slug>.md`, where `<section>` is `tutorials`, `how-to`, `reference` or `explanation`:

```md
---
title: Rotate Redis Credentials
description: One sentence shown under the title and in search results.
order: 7          # position in the sidebar section (lower first)
product: oss      # optional badge: oss | pro | console
---

Body in Markdown. Link other pages as /docs/how-to/seal-sensitive-payloads.
```

The page is served at `/docs/<section>/<slug>` and appears in the sidebar automatically. Fenced code blocks
are highlighted by Shiki (`crystal`, `yaml`, `bash`, `dockerfile`, `json`, ...). Sections and their labels are
`docsSections` in `src/data/site.config.ts`.

Every API, flag and variable a page names must exist in the source (`src/` of joobq, joobq-pro, joobqui).

## 2. Update pricing, comparison or features

| What | File |
| --- | --- |
| Pricing tiers, prices, card bullets | `src/data/pricing.ts` (set `placeholder: false` once a price is real) |
| Comparison table rows | `src/data/comparison.ts`: append `{ feature, oss, pro, console }` to a group; a cell is `true`, `false` or a short string |
| Feature grid and the three pillars | `src/data/features.ts` (icons: add a lucide name to `IconName` and to `ICONS` in `FeatureGrid.astro`) |
| Hero code tabs | `src/data/code-examples.ts` |
| Console mock-ups | `src/data/console-preview.ts` |
| FAQ | `src/data/faq.ts` |
| Hero copy, nav, footer, links, versions | `src/data/site.config.ts` |

## 3. Toggle or change the release banner

In `src/data/site.config.ts`:

```ts
announcement: {
  enabled: true,                       // false hides it
  text: 'JoobQ Pro v0.3.0 is out.',
  linkLabel: 'Read the notes',
  href: 'https://github.com/azutoolkit/joobq-pro/releases',
},
```

When you cut a release, also bump `versions` there (they are shown in the hero and must match what the docs were checked against).

## 4. Build and deploy

The output is plain files in `dist/`. Two environment variables control URLs at build time:

| Variable | Default | Use |
| --- | --- | --- |
| `SITE_URL` | `https://azutoolkit.github.io` | Canonical origin |
| `BASE_PATH` | `/` | Sub-path the site is served from |

- **GitHub Pages**: `.github/workflows/website.yml` builds on every change under `website/` and deploys from `master`
  with `BASE_PATH=/joobq`. Enable Pages once: Settings → Pages → Source: GitHub Actions.
- **Cloudflare Pages**: root directory `website`, build command `pnpm install && pnpm build`, output `dist`,
  environment `NODE_VERSION=22`, `SITE_URL=https://<your domain>`.
- **Netlify**: base directory `website`, build command `pnpm build`, publish directory `website/dist`,
  `NODE_VERSION=22`, `SITE_URL=https://<your domain>`.

Root-relative links in Markdown (`/docs/...`) get `BASE_PATH` added at build time; in components use `url()` from
`src/lib/url.ts`.
