// Site-wide settings: names, links, navigation, the announcement banner and the hero copy.
// Components read everything from here; change copy in this file, not in a component.

export interface NavLink {
  label: string;
  /** In-page anchor ("#pricing") or a site path ("/docs"). Site paths get the base prefix. */
  href: string;
}

export interface Announcement {
  enabled: boolean;
  /** Short text; keep it under ~90 characters so it fits on one line on a laptop. */
  text: string;
  linkLabel?: string;
  href?: string;
}

export interface Cta {
  label: string;
  href: string;
}

export interface HeroCopy {
  eyebrow: string;
  headline: string;
  subheadline: string;
  primary: Cta;
  secondary: Cta;
}

export interface Product {
  id: 'oss' | 'pro' | 'console';
  name: string;
  repo: string;
}

export interface DocsSection {
  /** Folder name under src/content/docs. */
  dir: string;
  label: string;
  blurb: string;
}

export interface SiteConfig {
  name: string;
  title: string;
  description: string;
  repoUrl: string;
  docsSourceUrl: string;
  /** Where "Contact sales" and Enterprise CTAs point. */
  contactUrl: string;
  versions: { core: string; pro: string; crystal: string };
  products: Product[];
  nav: NavLink[];
  navCta: Cta;
  announcement: Announcement;
  hero: HeroCopy;
  docsSections: DocsSection[];
  footer: { heading: string; links: NavLink[] }[];
  copyright: string;
  /** Labels used by the docs layout. */
  docsUi: {
    indexTitle: string;
    indexDescription: string;
    menu: string;
    overview: string;
    previous: string;
    next: string;
    onThisPage: string;
    edit: string;
  };
  notFound: { title: string; body: string; home: string; docs: string };
}

export const site: SiteConfig = {
  name: 'JoobQ',
  title: 'JoobQ: job queues and durable workflows for Crystal',
  description:
    'Open-source Redis job queues for Crystal, durable workflows and sagas with JoobQ Pro, and JoobQUI, a self-hosted operator console.',
  repoUrl: 'https://github.com/azutoolkit/joobq',
  docsSourceUrl: 'https://github.com/azutoolkit/joobq/tree/master/website/src/content/docs',
  // TODO: replace with the real sales / contact address.
  contactUrl: 'mailto:sales@example.com',
  // The versions the docs' examples were checked against (docs/quick-start in this repo).
  versions: { core: '0.5.1', pro: '0.2.2', crystal: '1.22.0' }, // crystal: shard.yml floor
  products: [
    { id: 'oss', name: 'JoobQ', repo: 'https://github.com/azutoolkit/joobq' },
    { id: 'pro', name: 'JoobQ Pro', repo: 'https://github.com/azutoolkit/joobq-pro' },
    { id: 'console', name: 'JoobQUI', repo: 'https://github.com/azutoolkit/joobqui' },
  ],
  nav: [
    { label: 'Features', href: '#features' },
    { label: 'Workflows', href: '#workflows' },
    { label: 'Console', href: '#console' },
    { label: 'Comparison', href: '#comparison' },
    { label: 'Pricing', href: '#pricing' },
    { label: 'Docs', href: '/docs' },
  ],
  navCta: { label: 'Get Started', href: '/docs/tutorials/first-10-minutes' },
  announcement: {
    enabled: true,
    text: 'Typed workflow DSL is available in JoobQ Pro v0.2.2 (authoring preview).',
    linkLabel: 'Build your first workflow',
    href: '/docs/tutorials/first-durable-workflow',
  },
  hero: {
    eyebrow: 'Open source core · Pro workflows · Self-hosted console',
    // The brief asked for "Sub-Millisecond ..."; the repository's measurements do not back a
    // sub-millisecond claim (design/implementation-validation.md), so the headline names no number.
    headline: 'Type-Safe Job Queues & Durable Workflows for Crystal.',
    subheadline:
      'Start with open-source Redis queues in 5 minutes. Scale to event-sourced sagas, deterministic replay, and a real-time self-hosted operator console without leaving Crystal.',
    primary: { label: 'Quickstart Guide', href: '/docs/tutorials/first-10-minutes' },
    secondary: { label: 'Explore JoobQUI Console', href: '#console' },
  },
  docsSections: [
    { dir: 'tutorials', label: 'Tutorials', blurb: 'Learn by doing, start to finish.' },
    { dir: 'how-to', label: 'How-To Guides', blurb: 'Steps for one task in production.' },
    { dir: 'reference', label: 'Reference', blurb: 'Exact names, flags, routes and roles.' },
    { dir: 'explanation', label: 'Explanation', blurb: 'How it works and why.' },
  ],
  footer: [
    {
      heading: 'Product',
      links: [
        { label: 'Features', href: '/#features' },
        { label: 'Console', href: '/#console' },
        { label: 'Pricing', href: '/#pricing' },
        { label: 'FAQ', href: '/#faq' },
      ],
    },
    {
      heading: 'Docs',
      links: [
        { label: 'Quickstart', href: '/docs/tutorials/first-10-minutes' },
        { label: 'Configuration', href: '/docs/reference/configuration-and-env-vars' },
        { label: 'REST API & metrics', href: '/docs/reference/rest-api-webhooks-and-metrics' },
        { label: 'Architecture', href: '/docs/explanation/architecture-and-deployment-models' },
      ],
    },
    {
      heading: 'Source',
      links: [
        { label: 'JoobQ on GitHub', href: 'https://github.com/azutoolkit/joobq' },
        { label: 'Book (docs/)', href: 'https://github.com/azutoolkit/joobq/tree/master/docs' },
        { label: 'Changelog & releases', href: 'https://github.com/azutoolkit/joobq/releases' },
      ],
    },
  ],
  copyright: 'JoobQ is MIT licensed. JoobQ Pro is commercial software.',
  docsUi: {
    indexTitle: 'Documentation',
    indexDescription: 'Tutorials, how-to guides, reference and explanation for JoobQ, JoobQ Pro and the JoobQUI console.',
    menu: 'Documentation menu',
    overview: 'Overview',
    previous: 'Previous',
    next: 'Next',
    onThisPage: 'On this page',
    edit: 'Edit this page on GitHub',
  },
  notFound: {
    title: 'Page not found',
    body: 'That page does not exist, or it moved.',
    home: 'Home',
    docs: 'Documentation',
  },
};
