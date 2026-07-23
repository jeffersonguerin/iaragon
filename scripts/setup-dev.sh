#!/bin/sh
# One-time developer setup. Idempotent — safe to re-run.
set -eu

cd "$(dirname "$0")/.."

# Versioned hooks are inert until git is pointed at them; this is the only
# switch local CI needs.
git config core.hooksPath .githooks
echo "setup-dev: core.hooksPath -> .githooks (pre-commit runs format + tests)"
