// Pricing cards. Seat, deployment and SSO limits come from the license tiers in joobqui
// (src/services/licensing/contracts.cr: Starter 5 seats / 1 deployment / no SSO, Team 25 / 3 / SSO,
// Enterprise unlimited / 10 / SSO). Prices are placeholders.
// TODO: set real prices (and the billing period) before publishing.
// TODO: confirm how JoobQ Pro (JOOBQ_PRO_LICENSE) is packaged with these tiers and what support each includes;
//       the cards below only state what the license tiers enforce.

export interface PricingTier {
  id: string;
  name: string;
  /** Display price, e.g. "$0" or "Contact us". */
  price: string;
  period?: string;
  /** Marks a placeholder price with a visible "placeholder" badge. Set false once real. */
  placeholder: boolean;
  blurb: string;
  features: string[];
  cta: { label: string; href: string };
  highlighted?: boolean;
}

export const pricingHeading = {
  eyebrow: 'Pricing',
  title: 'Free to start, licensed when you run the console',
  placeholderBadge: 'placeholder',
  // Shown on the highlighted tier. Not "Most popular": there are no sales figures to back that.
  popularBadge: 'Recommended',
};

export const pricingNote =
  'Paid tiers are licenses for the self-hosted JoobQUI console (a jq_lic_… key). Seat, deployment and SSO limits are the ones the license enforces; prices are placeholders.';

export const pricing: PricingTier[] = [
  {
    id: 'free',
    name: 'Free Forever',
    price: '$0',
    placeholder: false,
    blurb: 'JoobQ, the open-source core. MIT licensed, no key, no limits we enforce.',
    features: [
      'Typed jobs, queues, retries and dead letters',
      'Delayed, recurring and cron jobs',
      'Encrypted job properties',
      'REST API with OpenAPI 3.0',
      'Community support on GitHub',
    ],
    cta: { label: 'Start the quickstart', href: '/docs/tutorials/first-10-minutes' },
  },
  {
    id: 'starter',
    name: 'Starter',
    price: '$49', // TODO: set real prices
    period: '/ month',
    placeholder: true,
    blurb: 'One self-hosted console for a small team.',
    features: [
      'Everything in Free',
      'JoobQUI console: 5 seats, 1 deployment',
      'Live KPIs, workflows, dead-letter triage',
      'Roles, API tokens, audit log, TOTP',
      'Alerts to email, Slack, PagerDuty, webhooks',
    ],
    cta: { label: 'Get Starter', href: '/docs/how-to/deploy-licensed-self-hosted' },
  },
  {
    id: 'team',
    name: 'Team',
    price: '$199', // TODO: set real prices
    period: '/ month',
    placeholder: true,
    blurb: 'Several environments and single sign-on.',
    features: [
      'Everything in Starter',
      '25 seats, 3 deployments',
      'OpenID Connect single sign-on (PKCE)',
      'SSO group-to-role mapping',
    ],
    cta: { label: 'Get Team', href: '/docs/how-to/deploy-licensed-self-hosted' },
    highlighted: true,
  },
  {
    id: 'enterprise',
    name: 'Enterprise',
    price: 'Contact us',
    placeholder: false,
    blurb: 'Unlimited seats for organisations with many operators.',
    features: [
      'Everything in Team',
      'Unlimited seats, 10 deployments',
      'Terms agreed with you', // TODO: confirm Enterprise terms and support
    ],
    cta: { label: 'Contact sales', href: 'contact' },
  },
];
