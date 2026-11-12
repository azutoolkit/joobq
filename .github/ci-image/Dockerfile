# The image JoobQ's CI jobs run in: the Alpine Crystal compiler image plus only what the jobs call. Kept small on
# purpose: every job pulls it. A run downloads no system packages.
#   bash                               the workflow's step scripts
#   python3                            scripts/*.py (integration runner, Redis fixture, docs checks)
#   curl make gcc g++ musl-dev linux-headers openssl-dev   building the pinned Redis with TLS (scripts/install_test_redis.py; Redis 8 has a C++ part)
#   git                                shards, actions/checkout
#   tar zstd                           actions/cache
#
# Built and pushed by the `image` job of .github/workflows/ci.yml (when this directory changes) as
# ghcr.io/azutoolkit/joobq-ci:<TAG>. After changing this file, raise the number in TAG; ci.yml reads the tag from
# there, so no workflow needs editing.
FROM crystallang/crystal:1.22.1-alpine
LABEL org.opencontainers.image.source=https://github.com/azutoolkit/joobq
LABEL org.opencontainers.image.description="JoobQ CI: Crystal 1.22.1 on Alpine with the integration tools"
RUN apk add --no-cache bash python3 curl git make gcc g++ musl-dev linux-headers openssl-dev tar zstd
