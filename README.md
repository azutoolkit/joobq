# JoobQ

TODO: Write a description here

- [x] Priority queues based on number of workers
- [x] Reliable queue
- [x] Error Handling
- [x] Retry Jobs with automatic Delays
- [x] Cron Like Periodic Jobs
- [x] Delayed Jobs
- [] Expiring Jobs
- [] Batches?
- [] Approve Queue
- [] Job Locking / Disable Concurrent Execution(1 Job Per Instance)
- [] Throttle (Rate limit)
- [] Stop running Queues

## How to sell
- By Number of Workers
- By Worker Size
- By Number of Queues

## How To Integrate
- API Libraries
- Client Libraries
- 
## Installation

```yaml
dependencies:
    joobq:
        github: eliasjpr/joobq
```

```bash
$ shards install
```

## Usage

Scheduled Jobs 

```crystal 
JoobQ.scheduler.define do 
  at("5 4 * * *") { Somejob.perform }
end
```

## Development

TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/your-github-user/joobq/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Elias J. Perez](https://github.com/your-github-user) - creator and maintainer
