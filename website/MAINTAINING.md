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

## 5. Theme tokens

The look follows the JoobQUI control-plane console. Every colour is a CSS variable in `src/styles/global.css`:
dark values on `:root`, light values on `:root[data-theme='light']`, mapped to Tailwind names in `@theme inline`
(`bg-surface`, `text-muted`, `text-accent`, `border-line`, ...). Components never use raw colours.

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| `bg` / `surface` / `surface-2` | `#0f151d` / `#11161f` / `#0c1118` | `#f6f7f9` / `#ffffff` / `#eef0f3` | Page, cards, banded sections |
| `line` | `#202731` | `#dfe3e8` | 1px borders |
| `ink` / `muted` / `faint` | `#e8ebf1` / `#a0a6b0` / `#8a919c` | `#171717` / `#4c505a` / `#5d626c` | Text |
| `accent` | `#19cec6` | `#006d6d` | The only accent: links, eyebrows, primary button |
| `ok` / `warn` / `err` | `#8fc990` / `#c7b77c` / `#fb9890` | `#064b34` / `#7d6700` / `#c01d27` | Status pills only |
| `pro` | `#a78bfa` | `#7c3aed` | Small marker for JoobQ Pro, nothing else |

- To change the accent, set `--accent`, `--accent-hover`, `--accent-ink` (text on the accent) and `--accent-tint`
  in both blocks. Keep text tokens at 4.5:1 or more against `bg`, `surface` and `surface-2` (WCAG AA); the light
  accent is darker than the console's `#007c7c` for that reason.
- Building blocks: `.panel`, `.eyebrow`, `.label`, `.pill` + `.pill-{ok,warn,err,accent,pro,neutral}` (`.pill-dot`
  adds the dot), `.kpi`, `.icon-tile`, `.btn-primary`, `.btn-secondary`, `.table-hairline`. No glows, gradient text
  or shadows beyond the panel hairline.
- The theme: an inline script in `BaseLayout.astro` sets `data-theme` before first paint (saved choice in
  `localStorage` key `joobq-theme`, else the system setting, else dark); the navbar button toggles it.
- Code blocks use Shiki's dual themes (`github-light` / `github-dark-dimmed`, `astro.config.mjs` and `CodeTabs.astro`)
  and follow `data-theme` through the `--shiki-*` variables.
- Trust cues (hero, console mock-up) are `trust` in `src/data/site.config.ts`. Only claims the source backs: no
  certifications, SLAs, customer logos or "tamper-proof" audit.
