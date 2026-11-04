// Data for the stylized console mock-ups on the landing page. Numbers are illustrative sample
// data (labelled as such on the page); names, event types, roles and routes are the real ones
// from joobqui and joobq-pro, so the mock never shows a screen the console does not have.

export type Tone = 'cyan' | 'emerald' | 'amber' | 'violet' | 'rose' | 'slate';

export interface Kpi {
  label: string;
  value: string;
  unit?: string;
  delta?: string;
  tone: Tone;
}

export interface GraphNode {
  id: string;
  kind: 'activity' | 'signal' | 'timer';
  status: 'completed' | 'retrying' | 'waiting' | 'pending';
  note?: string;
}

export interface HistoryRow {
  seq: number;
  type: string;
  step?: string;
  detail: string;
  tone: Tone;
}

export interface DeadLetter {
  jid: string;
  job: string;
  queue: string;
  error: string;
  attempts: number;
}

export interface RoleRow {
  capability: string;
  viewer: boolean;
  operator: boolean;
  admin: boolean;
}

export interface ConsoleTab {
  id: 'kpis' | 'workflow' | 'dlq' | 'access';
  label: string;
  title: string;
  description: string;
  bullets: string[];
  /** The console route the mock imitates. */
  route: string;
}

export const consolePreview = {
  eyebrow: 'JoobQUI console',
  heading: 'The operator console for JoobQ and JoobQ Pro',
  intro:
    'JoobQUI runs next to your workers and reads the same Redis. Every screen below is a mock-up with sample numbers; the views, actions and roles are the console’s own.',
  sampleNote: 'Mock-up with sample data',
  /** Labels drawn inside the mock windows. */
  labels: {
    host: 'joobqui.internal',
    live: 'live · stream connected · window 15m',
    sparkline: 'throughput · all queues',
    history: 'event history',
    scrubber: 'Time travel through the history (mock-up)',
    selected: 'selected',
    actions: ['Export CSV', 'Purge', 'Redrive'],
    redriveCall: 'POST /api/v1/dlq/redrive →',
    audit: 'audit log',
  },
  tabs: [
    {
      id: 'kpis',
      label: 'Live KPIs',
      title: 'Throughput and latency, as it happens',
      description:
        'The overview listens to a WebSocket stream of lifecycle events and metric ticks: throughput, queue depth and p50 / p95 / p99 latency for all queues or one.',
      bullets: ['Windows from 1 minute to 7 days', 'Per-queue latency percentiles', 'Shows when the live stream drops'],
      route: '/ui/',
    },
    {
      id: 'workflow',
      label: 'Workflow graph',
      title: 'Each run as a graph, with its full history',
      description:
        'A run’s steps drawn as a graph, and every event of its history. Scrub back through the history and the page folds the state to that point.',
      bullets: ['Signal, query, cancel, terminate', 'Retry a failed step, re-drive a run', 'Replay against the deployed code'],
      route: '/ui/workflows',
    },
    {
      id: 'dlq',
      label: 'DLQ triage',
      title: 'Dead letters, triaged in bulk',
      description:
        'Browse dead letters with their error and masked payload, then re-drive or purge many at once; each job’s outcome is reported. Bulk workflow actions take a dry run first.',
      bullets: ['Outcome per job: succeeded, missing, unredrivable', 'CSV / JSON export (10,000 max)', 'Dry run for bulk workflow actions'],
      route: '/ui/dlq',
    },
    {
      id: 'access',
      label: 'RBAC · SSO · MFA · Audit',
      title: 'Access control an auditor can read',
      description:
        'Three roles enforced by the server on every route, admin-issued API tokens, TOTP two-factor, OpenID Connect single sign-on, and an audit row for every state change.',
      bullets: ['Roles mapped from SSO groups', 'Critical changes write the audit row first', 'Audit export to CSV / JSON'],
      route: '/ui/access',
    },
  ] satisfies ConsoleTab[],

  kpis: [
    { label: 'Throughput', value: '1,284', unit: 'jobs/s', delta: '+6.2%', tone: 'cyan' },
    { label: 'p50', value: '3.1', unit: 'ms', tone: 'emerald' },
    { label: 'p95', value: '11.8', unit: 'ms', tone: 'emerald' },
    { label: 'p99', value: '27.4', unit: 'ms', tone: 'amber' },
  ] satisfies Kpi[],
  /** 0..100 heights for the throughput sparkline. */
  series: [38, 42, 40, 47, 52, 49, 55, 61, 58, 64, 60, 66, 71, 68, 74, 70, 77, 73, 79, 82, 78, 84, 80, 86],
  queues: [
    { name: 'orders', depth: 128, workers: 10, state: 'running' },
    { name: 'emails', depth: 12, workers: 4, state: 'running' },
    { name: 'reports', depth: 0, workers: 2, state: 'paused' },
  ],

  workflow: {
    name: 'order-fulfilment',
    runId: 'A-1042',
    status: 'running',
    nodes: [
      { id: 'reserve_inventory', kind: 'activity', status: 'completed' },
      { id: 'charge_card', kind: 'activity', status: 'completed', note: 'attempt 2' },
      { id: 'manager_approval', kind: 'signal', status: 'waiting', note: 'signal: approve' },
      { id: 'pack_items', kind: 'activity', status: 'pending' },
      { id: 'cool_down', kind: 'timer', status: 'pending', note: '2s' },
      { id: 'notify_customer', kind: 'activity', status: 'pending' },
    ] satisfies GraphNode[],
    history: [
      { seq: 1, type: 'WorkflowStarted', detail: 'input {order, amount}', tone: 'cyan' },
      { seq: 2, type: 'StepScheduled', step: 'reserve_inventory', detail: 'attempt 1', tone: 'slate' },
      { seq: 4, type: 'StepCompleted', step: 'reserve_inventory', detail: 'output {reservation}', tone: 'emerald' },
      { seq: 6, type: 'StepFailed', step: 'charge_card', detail: 'payment gateway timed out', tone: 'rose' },
      { seq: 7, type: 'StepRetrying', step: 'charge_card', detail: 'backoff 1.5s', tone: 'amber' },
      { seq: 9, type: 'StepCompleted', step: 'charge_card', detail: 'attempt 2', tone: 'emerald' },
      { seq: 10, type: 'StepScheduled', step: 'manager_approval', detail: 'waits for signal approve', tone: 'violet' },
    ] satisfies HistoryRow[],
  },

  deadLetters: [
    { jid: '9f2c…a41e', job: 'WelcomeEmailJob', queue: 'emails', error: 'SMTP gateway timeout', attempts: 4 },
    { jid: '3b7d…0c19', job: 'ChargeJob', queue: 'billing', error: 'decryption_error', attempts: 1 },
    { jid: 'c81a…77f2', job: 'WelcomeEmailJob', queue: 'emails', error: 'SMTP gateway timeout', attempts: 4 },
    { jid: '04ee…d3b8', job: 'SyncLedgerJob', queue: 'ledger', error: 'connection refused', attempts: 4 },
  ] satisfies DeadLetter[],
  bulkResult: { succeeded: 3, missing: 0, unredrivable: 1, conflicted: 0 },

  roles: [
    { capability: 'Read queues, jobs, workflows, metrics', viewer: true, operator: true, admin: true },
    { capability: 'Pause queues, redrive dead letters', viewer: false, operator: true, admin: true },
    { capability: 'Signal, cancel, terminate workflows', viewer: false, operator: true, admin: true },
    { capability: 'Promote and retire worker builds', viewer: false, operator: false, admin: true },
    { capability: 'Users, API tokens, channels, audit log', viewer: false, operator: false, admin: true },
  ] satisfies RoleRow[],
  audit: [
    { action: 'token.create', actor: 'ada@acme.io', role: 'admin', outcome: 'ok' },
    { action: 'workflow.bulk_cancel', actor: 'lin@acme.io', role: 'operator', outcome: 'ok' },
    { action: 'mfa.reset', actor: 'cli:root', role: 'admin', outcome: 'ok' },
    { action: 'dlq.redrive', actor: 'lin@acme.io', role: 'operator', outcome: 'ok' },
  ],
  security: [
    { label: 'Single sign-on', value: 'OpenID Connect · PKCE S256' },
    { label: 'Two-factor', value: 'TOTP · 10 recovery codes' },
    { label: 'Session', value: '60 min · revoked server-side' },
  ],
};
