#!/usr/bin/env bash
# Claude SessionEnd-owned watcher shutdown (full-session teardown only).
#
# Registered in tracked .claude/settings.json as a SessionEnd command hook.
# Claude Code fires SessionEnd exactly once, when the whole session actually
# terminates (logout, prompt-input exit, resume-into-another-session, and so on),
# NEVER per turn. That is the one signal that cleanly distinguishes a genuine
# full-session teardown from a routine per-turn Stop or the harness reaping the
# arm's tracked background task every minute or two.
#
# Why this exists: bin/fm-watch-arm.sh launches the watcher DETACHED in its own
# session so a routine arm reap no longer drags supervision down with it (the
# reaping fix). The deliberate cost of that decoupling is that a full-session
# teardown would otherwise leave the watcher ORPHANED and running indefinitely.
# The watcher has NO idle self-exit: its main loop keeps beating, holding the
# lock, polling, and enqueuing wakes nobody drains, and exits only on an
# actionable wake, singleton self-eviction, or a signal. This hook closes that
# gap: when the owning session is really going away it explicitly stops THIS
# home's watcher now, via bin/fm-watch-arm.sh --shutdown, which is home-scoped
# and identity-verified. It does NOT re-couple routine teardown to the watcher -
# only SessionEnd runs it.
#
#   - reason=clear: /clear keeps the SAME session alive with a cleared context,
#     so it is NOT a teardown. Skip it and leave the watcher running; the session
#     (and its per-turn auto-arm) continues.
#   - Scope: only a genuine primary checkout or validly marked secondmate home,
#     the exact fm-turnend-guard.sh / auto-arm scope. Child worktrees stay inert.
#   - Identity: only the session that OWNS this home's state/.lock may stop the
#     watcher it armed. A foreign owner, missing lock, or unresolved ancestry
#     leaves the watcher alone. This never recovers or claims a lock - it is a
#     teardown path, not an arming path.
#   - AFK: while state/.afk exists the away daemon owns the watcher and outlives
#     this Claude session, so this hook must not stop it.
#
# It never blocks the session teardown and never prints to stdout. On any
# uncertainty it exits 0 and leaves the watcher running; there is no self-retire
# backstop, so the watcher keeps running until an actionable wake, singleton
# self-eviction, or a signal.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# Consume the SessionEnd payload once (a slow writer must never wedge on a full
# pipe) and read its termination reason. /clear reports reason=clear and keeps
# the session alive, so it is the one reason that must NOT stop the watcher.
payload=$(cat 2>/dev/null || true)
reason=$(printf '%s' "$payload" \
  | grep -o '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -1 \
  | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')
[ "$reason" = clear ] && exit 0

# Scope: genuine primary home only.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# AFK: the away daemon owns the watcher and outlives this session.
[ -e "$STATE/.afk" ] && exit 0

# Identity: only the lock-owning session stops the watcher it armed.
fm_session_lock_owned_by_self "$STATE" || exit 0

# Stop THIS home's watcher now instead of orphaning it. --shutdown is home-scoped
# and identity-verified, exits 0 whether or not a watcher was running, and never
# relaunches.
"$SCRIPT_DIR/fm-watch-arm.sh" --shutdown >/dev/null 2>&1 || true
exit 0
