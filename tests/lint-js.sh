#!/usr/bin/env bash
# tests/lint-js.sh: ESLint the GNOME Shell extensions in Docker (no node_modules or npm cache on the host).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# node:24-slim, pinned by digest.
IMAGE="node:24-slim@sha256:a5f4366e834695d5f363b920c104953a535d3a9864d1bdf74566a0ebe01daee5" # gitleaks:allow (image digest)

# node_modules lives in a named volume mounted over the repo's node_modules path. The container runs
# as root because a fresh volume is root-owned; npm only writes into that volume, ESLint writes nothing.
docker run --rm -e HOME=/tmp -e npm_config_cache=/tmp/npm \
	-v "$ROOT":/src -v ubuntu-ostrich-node-modules:/src/node_modules -w /src "$IMAGE" \
	sh -c 'npm ci --no-audit --no-fund --loglevel=error && npx eslint modules/gnome/extensions spikes/*-ext tests/vm/*.js'
