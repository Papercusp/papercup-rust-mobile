#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Guards the pre-push hook written by tools/install-git-hooks.sh.
# An automated Papercusp git-sync push (PAPERCUSP_GIT_SYNC_PUSH=1) must NOT run
# `make check`: git holds the remote connection open while pre-push runs, and
# the multi-minute check let GitHub close it (WI-10006870). Every other push
# must still run `make check` and be blocked when it fails.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/repo/tools" "$WORK/bin"
cp "$REPO_ROOT/tools/install-git-hooks.sh" "$WORK/repo/tools/"
git -C "$WORK/repo" init -q
"$WORK/repo/tools/install-git-hooks.sh" >/dev/null
HOOK="$WORK/repo/.git/hooks/pre-push"
[ -x "$HOOK" ] || { echo "FAIL: hook not installed" >&2; exit 1; }

# Fake make: records each call and exits with $FAKE_MAKE_RC.
cat > "$WORK/bin/make" <<'FAKE'
#!/usr/bin/env bash
echo "make $*" >> "$FAKE_MAKE_LOG"
exit "${FAKE_MAKE_RC:-0}"
FAKE
chmod +x "$WORK/bin/make"

run_hook() { # $1 = marker value or "", $2 = fake make rc; prints the hook rc
    local rc=0
    : > "$WORK/make.log"
    (cd "$WORK/repo" && PATH="$WORK/bin:$PATH" FAKE_MAKE_LOG="$WORK/make.log" \
        FAKE_MAKE_RC="$2" PAPERCUSP_GIT_SYNC_PUSH="$1" "$HOOK" origin url \
        </dev/null >/dev/null 2>&1) || rc=$?
    echo "$rc"
}

passed=0
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. git-sync push: hook succeeds WITHOUT invoking make, even if make would fail.
[ "$(run_hook 1 1)" = 0 ] || fail "git-sync push was blocked"
[ ! -s "$WORK/make.log" ] || fail "git-sync push ran make: $(cat "$WORK/make.log")"
passed=$((passed + 1))

# 2. Normal push with a passing check: make check runs, push allowed.
[ "$(run_hook "" 0)" = 0 ] || fail "passing check blocked the push"
grep -qx 'make check' "$WORK/make.log" || fail "normal push did not run make check"
passed=$((passed + 1))

# 3. Normal push with a failing check: push blocked (the gate still holds).
[ "$(run_hook "" 1)" != 0 ] || fail "failing check did not block the push"
grep -qx 'make check' "$WORK/make.log" || fail "failing push did not run make check"
passed=$((passed + 1))

# 4. Any marker value other than exactly 1 does not skip the gate.
[ "$(run_hook 0 1)" != 0 ] || fail "PAPERCUSP_GIT_SYNC_PUSH=0 skipped the gate"
passed=$((passed + 1))

echo "pre-push hook tests: $passed passed"
