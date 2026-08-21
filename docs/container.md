# Running QuotaBar in a container

QuotaBar reads quota by executing the AI coding CLIs installed on the machine it
runs on. The published image deliberately **does not ship those CLIs** — they are
third-party software with their own licences and release cadences, and bundling
them would tie a QuotaBar release to theirs.

So a bare run finds nothing, and says so:

```console
$ docker run --rm ghcr.io/bebepewpew/quotabar
quotabar: No supported CLI found. Install codex, claude or gemini and authenticate it.
```

That is correct behaviour, not a broken image. There are two ways to make it
useful.

## 1. Mount a host installation

`claude` and `codex` are native executables and mount cleanly on their own.
`gemini` is a `#!/usr/bin/env node` script, so it needs node and its
`node_modules` too — mounting the script alone will not work.

```console
$ docker run --rm --network host \
    -v ~/.local/bin/claude:/usr/local/bin/claude:ro \
    -v ~/.claude:/home/quotabar/.claude \
    -v ~/.claude.json:/home/quotabar/.claude.json \
    ghcr.io/bebepewpew/quotabar --provider claude
Claude Code  Session       13%  █░░░░░░░░░  resets in 3h 44m
Claude Code  Weekly        16%  ██░░░░░░░░  resets in 1d 9h
```

You are mounting your own credential directory so the vendor's CLI can read it.
QuotaBar itself never reads, copies or stores credentials.

## 2. Derive an image with the CLIs you use

```dockerfile
FROM ghcr.io/bebepewpew/quotabar
USER root
RUN apt-get -q update \
 && apt-get -q install -y --no-install-recommends nodejs npm \
 && npm install -g @anthropic-ai/claude-code @google/gemini-cli \
 && rm -rf /var/lib/apt/lists/*
USER quotabar
```

Then mount only the auth directories at run time.

## Building it yourself

The context is `dist/`, not the repository root — `.dockerignore` excludes
everything else, because the root holds an executable zsh dev wrapper that is
also called `quotabar` and would otherwise be the file copied in.

```console
$ swift build -c release --static-swift-stdlib
$ mkdir -p dist && cp .build/release/quotabar dist/
$ docker build -f packaging/Dockerfile -t quotabar .
```

These are the three lines `packaging/Dockerfile` records, and the ones
`release.yml` runs. The configuration is not optional: the image ships no Swift
runtime, so `--static-swift-stdlib` is required, and the copy above reads
`.build/release/` — a build without `-c release` writes `.build/debug/` and
leaves it nothing to stage. Without a local toolchain,
`./quotabar build -c release --static-swift-stdlib` runs the same build inside
`swift:6.3-noble` and leaves the same `.build/release/quotabar` behind, owned by
you.

## Notes

- The image runs as uid 1000, so a mounted auth directory is not writable by
  accident.
- `tini` is PID 1 so `docker stop` is honoured immediately and probe
  grandchildren are reaped rather than accumulating across `--watch` cycles.
- `expect` is included because the Gemini probe drives an interactive TUI and
  needs a pseudo-terminal. Codex and Claude Code use plain pipes.
