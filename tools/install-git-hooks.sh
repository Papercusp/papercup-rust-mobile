#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Installs a git pre-push hook that runs `make check` (fmt + clippy + tests)
# before allowing a push. Idempotent — safe to re-run.
#
# Usage:
#   ./tools/install-git-hooks.sh
#
# To bypass on a one-off basis: `git push --no-verify`.
# To uninstall: rm .git/hooks/pre-push

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/.git/hooks/pre-push"

if [ ! -d "$REPO_ROOT/.git" ]; then
    echo "ERROR: $REPO_ROOT is not a git repository" >&2
    exit 1
fi

cat > "$HOOK" <<'PREPUSH'
#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Installed by tools/install-git-hooks.sh — runs `make check`
# (fmt-check + clippy -D warnings + cargo test --workspace) before
# every push. Bypass with `git push --no-verify`.
#
# Papercusp git-sync pushes set PAPERCUSP_GIT_SYNC_PUSH=1 and are skipped.
# git opens the remote connection BEFORE it runs pre-push, so a multi-minute
# `make check` holds GitHub's session idle until the remote closes it and
# the automated push dies with SIGPIPE (WI-10006870). This is the same skip
# the Papercusp superproject's pre-push hook makes for git-sync.
set -euo pipefail
if [ "${PAPERCUSP_GIT_SYNC_PUSH:-}" = "1" ]; then
    echo "pre-push: skipping make check for the automated git-sync push" >&2
    exit 0
fi
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
echo "▶ pre-push: make check"
if ! make check; then
    echo "✗ pre-push: 'make check' failed — fix or 'git push --no-verify' to bypass" >&2
    exit 1
fi
echo "✓ pre-push: make check passed"
PREPUSH

chmod +x "$HOOK"
echo "✓ Installed pre-push hook at $HOOK"
echo "  Bypass with: git push --no-verify"
echo "  Uninstall:   rm $HOOK"
