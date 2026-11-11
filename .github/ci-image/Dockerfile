# The image JoobQ's CI jobs run in: the Crystal compiler plus the system packages the jobs used to install with apt
# at the start of every run. A run then downloads no system packages, so an outage of Ubuntu's mirrors (11 Nov 2026:
# GitHub's runners could not resolve them for hours) no longer fails every job.
#
# Built and pushed by .github/workflows/ci-image.yml as ghcr.io/azutoolkit/joobq-ci:<TAG>. After changing this file,
# raise the number in TAG and the image tag in crystal.yml and docs.yml.
FROM crystallang/crystal:1.22.1
LABEL org.opencontainers.image.source=https://github.com/azutoolkit/joobq
LABEL org.opencontainers.image.description="JoobQ CI: Crystal 1.22.1 with the integration tools"
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      python3 openssl curl libssl-dev build-essential ca-certificates git \
 && rm -rf /var/lib/apt/lists/*
