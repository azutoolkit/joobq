// The three-pillar ecosystem strip and the feature grid. Every claim here is backed by the
// source of the product it names; keep it that way when adding rows.

export type Edition = 'oss' | 'pro' | 'console';

/** Icon names from lucide (https://lucide.dev/icons). Add a name to ICONS in FeatureGrid.astro to use it. */
export type IconName =
  | 'layers'
  | 'workflow'
  | 'monitor'
  | 'repeat'
  | 'clock'
  | 'lock'
  | 'gauge'
  | 'git-branch'
  | 'history'
  | 'shield'
  | 'bell'
  | 'activity'
  | 'users'
  | 'archive'
  | 'search'
  | 'server';

export interface Pillar {
  edition: Edition;
  name: string;
  tag: string;
  summary: string;
  points: string[];
  cta: { label: string; href: string };
}

export interface Feature {
  edition: Edition;
  icon: IconName;
  title: string;
  body: string;
}

export interface FeatureSection {
  /** Anchor id on the landing page. */
  id: string;
  eyebrow: string;
  title: string;
  intro: string;
  features: Feature[];
}

export const editionLabels: Record<Edition, string> = {
  oss: 'JoobQ · OSS',
  pro: 'JoobQ Pro',
  console: 'JoobQUI',
};

export interface SectionHeading {
  eyebrow: string;
  title: string;
  intro?: string;
}

export const pillarsHeading: SectionHeading = {
  eyebrow: 'One ecosystem, three steps',
  title: 'Start with the open-source queue. Add what you need when you need it.',
};

export const pillars: Pillar[] = [
  {
    edition: 'oss',
    name: 'JoobQ',
    tag: 'Open source · MIT',
    summary: 'Redis-backed job queues for Crystal, with typed jobs and nothing else to run.',
    points: [
      'Typed `JoobQ::Job` structs, per-queue workers and throttles',
      'Exponential-backoff retries and a dead-letter set',
      'Delayed, recurring and cron jobs',
      'AES-256-GCM `encrypted_property` job fields',
      'REST API with an OpenAPI 3.0 description',
    ],
    cta: { label: 'Quickstart', href: '/docs/tutorials/first-10-minutes' },
  },
  {
    edition: 'pro',
    name: 'JoobQ Pro',
    tag: 'Commercial shard',
    summary: 'A durable workflow engine and production extensions on top of the same queues.',
    points: [
      'Workflows whose state is a fold of an append-only Redis history',
      'Sagas: compensations run newest first on failure or cancel',
      'Signals, queries, updates, timers, child workflows, scopes',
      'Deterministic replay, versioning gates and worker build ids',
      'Batches, unique jobs, rate limits, metrics and alerting',
    ],
    cta: { label: 'First workflow', href: '/docs/tutorials/first-durable-workflow' },
  },
  {
    edition: 'console',
    name: 'JoobQUI',
    tag: 'Self-hosted console',
    summary: 'An operator console you run next to your workers, with your data in your database.',
    points: [
      'Live KPIs, queues, jobs and dead letters over a WebSocket stream',
      'Workflow graph, event history with time travel, bulk actions',
      'Viewer / operator / admin roles, API tokens and an audit log',
      'TOTP two-factor and OpenID Connect single sign-on',
      'Prometheus `/metrics` and a JSON `/api/v1` with OpenAPI 3.1',
    ],
    cta: { label: 'Deploy it', href: '/docs/how-to/deploy-licensed-self-hosted' },
  },
];

export const featureSections: FeatureSection[] = [
  {
    id: 'features',
    eyebrow: 'Queues',
    title: 'Background jobs the Crystal way',
    intro:
      'Jobs are structs checked by the compiler. JoobQ keeps them in Redis, runs them on fibers, and stops cleanly on SIGTERM.',
    features: [
      {
        edition: 'oss',
        icon: 'layers',
        title: 'Typed jobs and queues',
        body: 'Include `JoobQ::Job`, implement `perform`, register a queue with a worker count. Arguments are JSON-serialized, and each job class publishes a JSON schema for the REST API.',
      },
      {
        edition: 'oss',
        icon: 'repeat',
        title: 'Retries and dead letters',
        body: 'Three retries by default with exponential backoff; exhausted jobs move to the dead-letter set with their error context, ready to redrive.',
      },
      {
        edition: 'oss',
        icon: 'clock',
        title: 'Delayed, recurring and cron',
        body: '`delay(for:)`, `enqueue_at`, `schedule(every:)` and a `scheduler` block with `cron` and `every`, evaluated in a time zone.',
      },
      {
        edition: 'oss',
        icon: 'gauge',
        title: 'Throttling and graceful drain',
        body: 'Per-queue `throttle: {limit:, period:}`. `JoobQ.forge` traps SIGTERM, finishes running jobs and puts back what outlives the deadline.',
      },
      {
        edition: 'oss',
        icon: 'lock',
        title: 'Sealed job arguments',
        body: '`encrypted_property` stores chosen fields as AES-256-GCM sealed strings bound to the job class and field, with key rotation.',
      },
      {
        edition: 'pro',
        icon: 'activity',
        title: 'Metrics, batches and limits',
        body: 'Pro adds latency percentiles, alert rules, batches with callbacks, unique jobs, rate limiting and job timeouts.',
      },
    ],
  },
  {
    id: 'workflows',
    eyebrow: 'Workflows · JoobQ Pro',
    title: 'Durable workflows that replay, not just retry',
    intro:
      'A workflow is a declared graph of steps. Every state change is an event appended to its history in Redis by one Lua script, so a crashed worker loses nothing Redis kept.',
    features: [
      {
        edition: 'pro',
        icon: 'workflow',
        title: 'Sagas with compensation',
        body: 'Give a step a `compensate:` activity. On failure, cancel or timeout the completed steps are undone one at a time, newest first.',
      },
      {
        edition: 'pro',
        icon: 'git-branch',
        title: 'Signals, queries, updates, children',
        body: '`wait_for` a signal, answer a `query` from state, accept a validated `update`, run a `child` workflow, `timer`, `parallel` and `sequence`.',
      },
      {
        edition: 'pro',
        icon: 'history',
        title: 'Deterministic replay',
        body: '`replay(history, definition)` re-decides a recorded history against new code and reports the first divergence. `migrate` moves a run only if it agrees.',
      },
      {
        edition: 'pro',
        icon: 'server',
        title: 'Worker build ids',
        body: 'Pin each run to the build it started on, promote a new build for new runs, and retire the old one once nothing is pinned to it.',
      },
      {
        edition: 'pro',
        icon: 'search',
        title: 'Search attributes and schedules',
        body: 'Typed attributes (keyword, int, float, bool, time) to find runs, and cron or interval workflow schedules with overlap policy, catch-up and backfill.',
      },
      {
        edition: 'pro',
        icon: 'archive',
        title: 'Scopes, continue-as-new, archive',
        body: 'Cancel a group of steps while the rest goes on, roll long runs into new ones, and export closed runs (with redaction) before retention deletes them.',
      },
    ],
  },
];
