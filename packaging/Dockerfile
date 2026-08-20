# QuotaBar as a container.
#
# Read this before using it: QuotaBar works by executing the AI coding CLIs
# installed on the machine it runs on. This image deliberately does NOT ship
# those CLIs — they are third-party software with their own licences and release
# cadences, and vendoring them would tie a QuotaBar release to theirs.
#
# So a bare `docker run` of this image finds no providers and says so. That is
# correct behaviour, not a broken image. Use it one of two ways:
#
#   1. Derive from it and add the CLIs you use — see docs/container.md.
#   2. Mount a host installation. `claude` and `codex` are native executables and
#      mount cleanly on their own — verified: mounting the host `claude` binary
#      and its config into this image returns real quota. `gemini` is a
#      `#!/usr/bin/env node` script, so it needs node and its node_modules too.
#
# Built from the statically linked release binary, so this stage only needs a
# libc: the binary links libc, libstdc++, libm and libgcc and nothing else.

FROM debian:stable-slim

# expect is needed by the Gemini probe, which drives an interactive TUI and so
# requires a pseudo-terminal. Codex and Claude Code speak over plain pipes.
RUN apt-get -q update \
 && apt-get -q install -y --no-install-recommends expect ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

# Build with the staged binary as the context, exactly as release.yml does:
#
#   swift build -c release --static-swift-stdlib     # in swift:6.3-noble
#   mkdir -p dist && cp .build/release/quotabar dist/
#   docker build -f packaging/Dockerfile -t quotabar .
#
# There is no default: the repo root holds an executable zsh dev wrapper also
# named `quotabar`, and defaulting to it produced an image that shipped a shell
# script debian cannot run. .dockerignore now excludes everything but dist/, so
# a wrong path fails at COPY instead of silently succeeding.
ARG BINARY=dist/quotabar
COPY ${BINARY} /usr/local/bin/quotabar
RUN chmod 0755 /usr/local/bin/quotabar && quotabar --version

# QuotaBar never reads credentials; the provider CLIs it invokes do. Running as
# a non-root user keeps a mounted auth directory from being writable by accident.
RUN useradd --create-home --uid 1000 quotabar
USER quotabar
ENV XDG_CONFIG_HOME=/home/quotabar/.config

# tini reaps orphans and forwards signals. Without an init, quotabar is PID 1:
# the kernel discards default-action signals for a namespace init, so `docker
# stop` would be ignored for the whole grace period and then SIGKILL a probe
# mid-flight, and probe grandchildren re-parented to PID 1 would never be waited
# on — zombies accumulating across every --watch cycle.
ENTRYPOINT ["/usr/bin/tini", "--", "quotabar"]
