# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — GO target (go modules / go-118-fuzz-build). Builds
# ON TOP of the org C/C++ base (ghcr.io/savantenvs/base) — clang is needed to
# link the go-118-fuzz-build libFuzzer archive — adding a pinned Go toolchain
# + go-118-fuzz-build under /opt/toolchains/go, then runs the per-repo
# mayhem/build.sh.
#
# WHY a Go-specific template (SPEC §6.2 items 8/9, §6.5):
#   Go's GOPATH/GOMODCACHE default to $HOME/go. The commit build and the PATCH
#   RL re-run use DIFFERENT $HOMEs, so a cache left at the default would
#   vanish under the re-run identity. We pin GOROOT/GOPATH/GOMODCACHE at
#   FIXED, $HOME-independent paths under /opt/toolchains so (a) the toolchain
#   locks uniformly (§4/§5) and (b) the module cache the FIRST (online) build
#   fills is found again — by the SAME absolute GOMODCACHE — when build.sh
#   re-runs OFFLINE at the PATCH tier.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS

# ── Go toolchain @ a FIXED, lockable, $HOME-independent prefix ─────────────
# Pin the Go version AND its tarball sha256 (reproducible fetch). goawk's
# go.mod declares `go 1.20`, comfortably under this pin. go-118-fuzz-build is
# pinned by COMMIT (not @latest) so the module cache this build populates is
# deterministic; its release tag is a stale 2022 snapshot predating the
# .../testing shim.
ARG GO_VERSION=1.23.4
ARG GO_SHA256=6924efde5de86fe277676e929dc9917d466efa02fb934197bc2eba35d5680971
ARG GO118_FUZZ_BUILD_VERSION=a70c2aa677fa43583571959478decabe02a96cd6

ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/build-cache \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:${PATH}

USER root
# gawk: upstream's own test suite (interp/interp_test.go, TestInterp) cross-
# validates every interpreter test case against a REAL gawk binary (-awk flag,
# default "gawk") in addition to GoAWK itself — that's the load-bearing part
# of the behavioral oracle test.sh runs. Installing it here (online, first
# build) bakes the binary into the image layer, so the air-gapped PATCH
# re-run of test.sh needs no network.
RUN apt-get update && apt-get install -y --no-install-recommends gawk \
 && rm -rf /var/lib/apt/lists/*
RUN install -d /opt/toolchains/go-path \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz \
 && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
 && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm -f /tmp/go.tgz \
 # go-118-fuzz-build (the libFuzzer build path for native testing.F targets).
 # Installing it also seeds its module graph into GOMODCACHE, which build.sh
 # needs offline.
 && go version \
 && go install "github.com/AdamKorcz/go-118-fuzz-build@${GO118_FUZZ_BUILD_VERSION}" \
 && chmod -R a+rX /opt/toolchains/go \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it
 # must read the toolchain and read/refresh the module cache, so hand the
 # GOPATH to 2000.
 && chown -R 2000:2000 /opt/toolchains/go-path

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $GOMODCACHE (online, this first build) and builds the libFuzzer
# target(s) + the KAT probe.
RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
