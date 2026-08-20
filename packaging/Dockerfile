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
 && apt-get -q install -y --no-install-recommends expect ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Populated by the release workflow from the statically linked Linux build.
ARG BINARY=quotabar
COPY ${BINARY} /usr/local/bin/quotabar
RUN chmod 0755 /usr/local/bin/quotabar && quotabar --version

# QuotaBar never reads credentials; the provider CLIs it invokes do. Running as
# a non-root user keeps a mounted auth directory from being writable by accident.
RUN useradd --create-home --uid 1000 quotabar
USER quotabar
ENV XDG_CONFIG_HOME=/home/quotabar/.config

ENTRYPOINT ["quotabar"]
