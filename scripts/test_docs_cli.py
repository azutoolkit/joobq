#!/usr/bin/env python3
"""Validate the documented Azu CLI generator/operator path in a disposable project."""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile
import time

from test_docs_examples import ROOT, launch, redis_server, stop, tail


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--azu", type=Path, required=True, help="Built Azu CLI v0.1.59 binary")
    parser.add_argument("--dependencies", type=Path, default=ROOT / "examples/docs/core/lib")
    args = parser.parse_args()
    azu = str(args.azu.resolve())
    dependencies = args.dependencies.resolve()
    if not Path(azu).is_file() or not dependencies.is_dir():
        parser.error("Supply an existing CLI binary and installed Core fixture dependencies")
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("REDIS_", "JOOBQ_")) and key not in ("RACK_ENV", "CRYSTAL_ENV")}
    with tempfile.TemporaryDirectory(prefix="joobq-cli-docs-") as temporary:
        workspace = Path(temporary)
        (workspace / "lib").symlink_to(dependencies)
        shutil.copy2(ROOT / "examples/docs/core/shard.yml", workspace / "shard.yml")

        def command(arguments, environment):
            path = workspace / "command.log"
            with path.open("wb") as output:
                process = launch(arguments, workspace, environment, output)
                try:
                    code = process.wait(timeout=120)
                finally:
                    stop(process)
            text = tail(path)
            if code:
                raise RuntimeError(text)
            return text

        command([azu, "generate", "joobq", "--queue", "orders", "--workers", "2"], env)
        command([azu, "generate", "job", "ProcessOrder", "order_id:int64", "--yes"], env)
        assert (workspace / "src/jobs/process_order_job.cr").is_file()
        print("PASS released CLI generators", flush=True)
        with redis_server(workspace, env) as connected:
            log_path = workspace / "worker.log"
            with log_path.open("wb") as log:
                worker = launch([azu, "jobs:worker", "--queues", "orders", "--workers", "2"], workspace, connected, log)
                try:
                    deadline = time.monotonic() + 90
                    while "JoobQ initialized" not in tail(log_path):
                        if worker.poll() is not None or time.monotonic() > deadline:
                            raise RuntimeError(tail(log_path))
                        time.sleep(0.1)
                    (workspace / "src/enqueue_example.cr").write_text('require "./initializers/joobq"\nExampleJob.enqueue(message: "Hello, JoobQ!")\n')
                    command(["crystal", "run", "src/enqueue_example.cr"], connected)
                    deadline = time.monotonic() + 10
                    while "ExampleJob completed successfully" not in tail(log_path):
                        if time.monotonic() > deadline:
                            raise RuntimeError(tail(log_path))
                        time.sleep(0.1)
                    # Adapters may log before their JSON result; retain only that result line.
                    result = json.loads(command([azu, "jobs:status", "--queue", "orders", "--json"], connected).splitlines()[-1])
                    assert result["queues"][0]["completed"] >= 1, result
                    assert result["workers"] == [], "Baseline forge does not start WorkerRegistry"
                    command([azu, "jobs:dlq", "--queue", "orders", "--limit", "20", "--json"], connected)
                    command([azu, "jobs:retry", "--queue", "orders", "--limit", "1", "--dry-run"], connected)
                    command([azu, "jobs:pause", "--queue", "orders", "--force"], connected)
                    result = json.loads(command([azu, "jobs:status", "--queue", "orders", "--json"], connected).splitlines()[-1])
                    assert result["queues"][0]["paused"], result
                    command([azu, "jobs:resume", "--queue", "orders", "--force"], connected)
                finally:
                    stop(worker, grace=30)
                assert worker.returncode == 0, tail(log_path)
            print("PASS generated worker, completion, empty registry, DLQ, replay preview, pause/resume, shutdown", flush=True)


if __name__ == "__main__":
    main()
