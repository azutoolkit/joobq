// Code shown in the hero's tabs. Each sample is taken from real APIs:
// - job:      docs/quick-start/README.md and src/joobq/job.cr (JoobQ Core)
// - workflow: the order-fulfilment demo in joobqui (src/workflows/demo/order_fulfilment.cr) and the
//             JoobQ Pro DSL (src/workflows/dsl/builder.cr)
// - console:  joobqui Dockerfile.selfhosted and src/cli/self_hosted_cli.cr
// When an API changes, update the sample here and run `pnpm build`.

export type CodeLang = 'crystal' | 'yaml' | 'bash' | 'dockerfile' | 'json' | 'text';

export interface CodeFile {
  filename: string;
  lang: CodeLang;
  code: string;
}

export interface CodeExample {
  id: string;
  label: string;
  /** One sentence under the tab, saying what the sample does. */
  caption: string;
  product: 'oss' | 'pro' | 'console';
  files: CodeFile[];
}

export const heroExamples: CodeExample[] = [
  {
    id: 'job',
    label: 'Define a Job',
    caption: 'A typed job, a queue with two workers, one enqueue and one delayed job. MIT licensed.',
    product: 'oss',
    files: [
      {
        filename: 'src/worker.cr',
        lang: 'crystal',
        code: `require "joobq"

struct ProcessOrderJob
  include JoobQ::Job

  @queue   = "orders"
  @retries = 3

  getter order_id : Int64

  def initialize(@order_id : Int64)
  end

  def perform
    puts "Processed order #{order_id}"
  end
end

JoobQ.configure do
  queue "orders", 2, ProcessOrderJob,
    throttle: {limit: 100, period: 1.minute}
end

ProcessOrderJob.enqueue(order_id: 42_i64)
ProcessOrderJob.delay(for: 5.minutes, order_id: 43_i64)

JoobQ.forge # starts the workers; SIGTERM drains them`,
      },
    ],
  },
  {
    id: 'workflow',
    label: 'Durable Workflow & Saga',
    caption:
      'Every step is an event in the run’s Redis history. A failure after the charge refunds it and releases the stock, newest first.',
    product: 'pro',
    files: [
      {
        filename: 'src/order_fulfilment.cr',
        lang: 'crystal',
        code: `require "joobq_pro"
include JoobQPro::Workflows::DSL

struct Order
  include JSON::Serializable
  getter order : String
  getter amount : Int32
end

class ChargeCard
  def perform(input : Order, ctx : JoobQPro::Workflows::ActivityContext) : JSON::Any
    charge = Gateway.charge(input.amount, idempotency_key: ctx.dedupe_key)
    JSON.parse({charge: charge.id}.to_json)
  end
end
# ReserveInventory, ReleaseInventory, RefundCard, PackItems and
# NotifyCustomer are activities of the same shape.

OrderFulfilment = workflow "order-fulfilment", timeout: 1.hour do
  order = {order: input(:order), amount: input(:amount)}
  query "progress", ref("steps")

  step :reserve_inventory, ReserveInventory, input: order,
    compensate: compensation(ReleaseInventory)
  step :charge_card, ChargeCard, input: order,
    retry: retry_policy(attempts: 3, initial: 1500.milliseconds),
    compensate: compensation(RefundCard)
  wait_for :manager_approval, signal: :approve, timeout: 10.minutes
  step :pack_items, PackItems, input: order
  timer :cool_down, for: 2.seconds
  step :notify_customer, NotifyCustomer, input: order
end

worker = JoobQPro::Workflows::Worker.new.register(OrderFulfilment).start
id = worker.client.start("order-fulfilment", {order: "A-1042", amount: 4999})
worker.client.signal(id, "approve", {by: "ops@acme.io"})
worker.client.query(id, "progress")`,
      },
    ],
  },
  {
    id: 'console',
    label: 'Run Self-Hosted Console',
    caption:
      'Build the licensed image, point it at your PostgreSQL and the Redis your workers use, then create the first admin.',
    product: 'console',
    files: [
      {
        filename: 'terminal',
        lang: 'bash',
        code: `# joobq-pro is a private shard: pass a token that can read it as a BuildKit secret
docker build -f Dockerfile.selfhosted \\
  --secret id=github_token,env=GITHUB_TOKEN -t joobqui-selfhosted .

docker run -d --name joobqui -p 4000:4000 \\
  -e DATABASE_URL=postgres://joobqui@db:5432/joobqui \\
  -e REDIS_URL=rediss://default:\${REDIS_PASSWORD}@redis:6380/0 \\
  -e SESSION_SECRET="$(openssl rand -hex 32)" \\
  -e JOOBQUI_SECRETS_KEY="$(openssl rand -hex 32)" \\
  -e JOOBQUI_LICENSE_FILE=/run/secrets/joobqui_license \\
  -v "$PWD/license.key:/run/secrets/joobqui_license:ro" \\
  joobqui-selfhosted

# The first account created on the command line is an admin
docker exec -it joobqui ./joobqui-selfhosted accounts:create ada@acme.io ada
open http://localhost:4000/ui/`,
      },
    ],
  },
];
