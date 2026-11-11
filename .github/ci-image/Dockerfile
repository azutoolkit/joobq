# The image JoobQ's CI jobs run in: the Alpine Crystal compiler image plus only what the jobs call. Kept small on
# purpose: every job pulls it. A run downloads no system packages.
#   bash                               the workflow's step scripts
#   python3                            scripts/*.py (integration runner, Redis fixture, docs checks)
#   curl make gcc musl-dev linux-headers openssl-dev   building the pinned Redis with TLS (scripts/install_test_redis.py)
#   git                                shards, actions/checkout
#   tar zstd                           actions/cache
#
# Built and pushed by .github/workflows/ci-image.yml as ghcr.io/azutoolkit/joobq-ci:<TAG>. After changing this file,
# raise the number in TAG and the image tag in crystal.yml and docs.yml.
FROM crystallang/crystal:1.22.1-alpine
LABEL org.opencontainers.image.source=https://github.com/azutoolkit/joobq
LABEL org.opencontainers.image.description="JoobQ CI: Crystal 1.22.1 on Alpine with the integration tools"
RUN apk add --no-cache bash python3 curl git make gcc musl-dev linux-headers openssl-dev tar zstd
