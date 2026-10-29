#!/usr/bin/env python3
"""Build a checksum-pinned TLS Redis fixture; never starts or modifies a service."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tarfile
import tempfile

HASHES = {
    '7.4.12': '56588ee1648539556f2b6cf4e873e3734afbbe40fa952fec2fcd6b6d7dae2924',
    '8.0.6': '6d0a9913887a4972536f9da226f1575859c34d86354129163260a5f9c6bd4229',
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('version', choices=HASHES)
parser.add_argument('prefix', type=Path)
args = parser.parse_args()
prefix = args.prefix.resolve()
with tempfile.TemporaryDirectory(prefix='joobq-redis-build-') as temporary:
    root = Path(temporary)
    archive = root / 'redis.tar.gz'
    subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2", "--max-time", "60",
                    f"https://download.redis.io/releases/redis-{args.version}.tar.gz", "--output", str(archive)], check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != HASHES[args.version]:
        raise SystemExit('Redis source checksum mismatch')
    with tarfile.open(archive) as source:
        # Python 3.10 compatible path validation; official archive is pinned above.
        for member in source.getmembers():
            destination = (root / member.name).resolve()
            if not destination.is_relative_to(root) or member.issym() or member.islnk():
                raise SystemExit('unsafe archive entry')
        source.extractall(root)
    directory = root / f'redis-{args.version}'
    # One recursive make invocation: parallel top-level targets race while
    # building Redis 8 dependencies and can delete one another's archives.
    subprocess.run(['make', '-j2', 'BUILD_TLS=yes', 'MALLOC=libc', 'OPT=-O2'], cwd=directory, check=True)
    (prefix / 'bin').mkdir(parents=True, exist_ok=True)
    for name in ('redis-server', 'redis-cli'):
        destination = prefix / 'bin' / name
        destination.write_bytes((directory / 'src' / name).read_bytes())
        destination.chmod(0o755)
    subprocess.run([str(prefix / 'bin' / 'redis-server'), '--version'], check=True)
