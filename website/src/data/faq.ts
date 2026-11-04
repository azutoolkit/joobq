// Frequently asked questions. Answers are plain text; `code` spans use backticks.
// Sources are noted per answer so they can be re-checked when behaviour changes.

export interface FaqItem {
  question: string;
  answer: string[];
}

export const faqHeading = {
  eyebrow: 'FAQ',
  title: 'Questions operators ask first',
};

export const faq: FaqItem[] = [
  {
    // joobq README (Redis URL, TLS), joobq-pro README "Single Redis", joobqui api-contract (Redis 5, eviction).
    question: 'What Redis do I need?',
    answer: [
      'One Redis server, version 5 or newer, reachable by every worker and the console. Connect with `REDIS_URL` as `redis://`, `rediss://` (TLS with certificate and host-name checks) or a unix socket; ACL users are supported.',
      'Redis Cluster is not supported: keys are not hash-tagged. If losing the last second of workflow history on a crash is not acceptable, run Redis with AOF `appendfsync always`. Use a `noeviction` (or `volatile-*`) policy so the console never forgets a session revocation.',
    ],
  },
  {
    // joobqui README, OPERATIONS.md "What lives where", licensing/client.cr heartbeat payload.
    question: 'Where does my data live with the self-hosted console?',
    answer: [
      'In your infrastructure. Jobs, workflow histories and live events stay in your Redis; accounts, API token hashes, the audit log and notification channels go to your PostgreSQL.',
      'The license heartbeat sends the console’s origin, the number of active accounts and its version to the license service. Payload values whose keys look secret are masked in every view and export, and fields sealed with `encrypted_property` are shown as `[encrypted]`: the console holds no key to open them.',
    ],
  },
  {
    // joobq docs/quick-start/azu-application.md, azu_cli commands, joobqui is an Azu app.
    question: 'How does JoobQ fit with Crystal and Azu?',
    answer: [
      'JoobQ is a plain shard: `require "joobq"`, define jobs as structs and start workers with `JoobQ.forge`. It works in any Crystal program; Crystal 1.22 or newer is required.',
      'For Azu apps, the Azu CLI generates the JoobQ setup (`azu generate joobq`) and runs workers (`azu jobs:worker`); the JoobQUI console is itself an Azu application.',
    ],
  },
  {
    // joobqui src/services/licensing/client.cr (GRACE_WINDOW, heartbeat), src/handlers/licensed_gate.cr, OPERATIONS.md.
    question: 'What happens if the console cannot reach the license service?',
    answer: [
      'The console checks in every 15 minutes. If the license service cannot be reached, the last good license stays in force for 24 hours after the last successful check-in, as long as its paid-until date has not passed.',
      'After that, or when the license is expired, unpaid or disabled, `/api/v1` and `/metrics` answer `402 paid_license_required`; sign-in and account routes keep working. Queue workers do not depend on the license and keep processing jobs. `joobqui-selfhosted license:refresh` checks in on demand.',
    ],
  },
  {
    // design/implementation-validation.md, benchmarks/README.md.
    question: 'How fast is it?',
    answer: [
      'Throughput depends on payload size, TLS, Redis persistence and what your jobs do, so the repository ships its benchmark harness (`benchmarks/`) and the recorded runs and open performance gates in `design/implementation-validation.md` rather than a headline number. Measure completed jobs with your own workload.',
    ],
  },
  {
    // joobq-pro README "Guarantees and limits".
    question: 'Are jobs and activities exactly-once?',
    answer: [
      'No. JoobQ delivers at least once: after a crash or redelivery a job, or a workflow activity, can run again. Each workflow attempt starts at most once, and `ctx.dedupe_key` gives activities a stable key to pass to services that support idempotency.',
    ],
  },
];
