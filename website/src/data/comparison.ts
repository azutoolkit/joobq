// The edition comparison table. A cell is `true` (included), `false` (not included) or a short
// string (included, with a qualifier). Add a row by appending to a group's `rows`.

export type Cell = boolean | string;

export interface ComparisonRow {
  feature: string;
  oss: Cell;
  pro: Cell;
  console: Cell;
}

export interface ComparisonGroup {
  group: string;
  rows: ComparisonRow[];
}

export interface ComparisonColumn {
  key: 'oss' | 'pro' | 'console';
  name: string;
  sub: string;
}

export const comparisonHeading = {
  eyebrow: 'Comparison',
  title: 'What each part of the ecosystem gives you',
  intro: 'JoobQ Pro builds on the open-source core; JoobQUI operates both. The console column says what you can do from the console.',
};

export const comparisonColumns: ComparisonColumn[] = [
  { key: 'oss', name: 'JoobQ', sub: 'Open source (MIT)' },
  { key: 'pro', name: 'JoobQ Pro', sub: 'Commercial shard' },
  { key: 'console', name: 'JoobQUI', sub: 'Self-hosted console' },
];

export const comparison: ComparisonGroup[] = [
  {
    group: 'Queues and jobs',
    rows: [
      { feature: 'Typed jobs, Redis queues, per-queue workers', oss: true, pro: true, console: 'Pause, resume, clear, resize' },
      { feature: 'Retries with exponential backoff', oss: true, pro: true, console: 'Retry and delete jobs' },
      { feature: 'Dead-letter set and redrive', oss: true, pro: true, console: 'Bulk redrive and purge' },
      { feature: 'Delayed, recurring and cron jobs', oss: true, pro: true, console: 'Pause, resume, run now' },
      { feature: 'Queue throttling', oss: true, pro: true, console: false },
      { feature: 'Encrypted job properties (AES-256-GCM)', oss: true, pro: true, console: 'Shown as [encrypted]' },
      { feature: 'REST API with OpenAPI description', oss: 'OpenAPI 3.0', pro: 'OpenAPI 3.0', console: 'OpenAPI 3.1, /api/v1' },
      { feature: 'Batches, unique jobs, rate limiting, job timeouts', oss: false, pro: true, console: false },
    ],
  },
  {
    group: 'Durable workflows',
    rows: [
      { feature: 'Event-sourced history in Redis', oss: false, pro: true, console: 'Event history, time travel' },
      { feature: 'Sagas: compensation newest first', oss: false, pro: true, console: 'Cancel with compensation' },
      { feature: 'Signals, queries, updates, timers, child workflows', oss: false, pro: true, console: 'Signal, query, send updates' },
      { feature: 'Deterministic replay and migration', oss: false, pro: true, console: 'Replay, migrate (dry run)' },
      { feature: 'Cancellation scopes and continue-as-new', oss: false, pro: true, console: 'Cancel one scope' },
      { feature: 'Worker build ids', oss: false, pro: true, console: 'Promote, retire, re-pin' },
      { feature: 'Search attributes and workflow schedules', oss: false, pro: true, console: 'Filter runs, manage schedules' },
      { feature: 'Bulk operations with dry run', oss: false, pro: false, console: 'Up to 200 ids or a filter' },
    ],
  },
  {
    group: 'Operations and security',
    rows: [
      { feature: 'Latency percentiles (p50 / p95 / p99)', oss: false, pro: true, console: 'Live charts, 1 min to 7 days' },
      { feature: 'Alert rules', oss: false, pro: true, console: 'Rules, acknowledgement' },
      { feature: 'Email, Slack, PagerDuty and signed webhook channels', oss: false, pro: false, console: true },
      { feature: 'Prometheus metrics endpoint', oss: false, pro: false, console: '/metrics' },
      { feature: 'Roles, API tokens and audit log', oss: false, pro: false, console: 'viewer · operator · admin' },
      { feature: 'TOTP two-factor and OIDC single sign-on', oss: false, pro: false, console: 'SSO from the Team tier' },
      { feature: 'Secret-looking payload keys masked', oss: false, pro: 'History archive redaction', console: 'Every view and export' },
    ],
  },
];
