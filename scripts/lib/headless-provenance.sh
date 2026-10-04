#!/usr/bin/env bash
# headless-provenance.sh — a headless claude-code worker's own session id, bound
# to the team its bridge serves.
#
# Why: claude re-exports the worker's own session id into every Bash tool it runs
# on a --resume turn, so the worker's send.sh sees a session id that is not the
# session team's. send.sh's cross-session guard would then refuse the worker's
# legitimate reply to its own team. The bridge (the only party that knows which
# team it serves) publishes run/headless-sid.<sid> before each turn; send.sh
# accepts a send only when the caller's sid has a live record for exactly the
# destination team. The record names the bridge process by pid and start token,
# so a stale record left by a crashed bridge, or a recycled pid, authorizes
# nothing. This stops accidental cross-team sends; it is not an authentication
# boundary (any process of the same user can write run/).
#
# Requires SKILL_DIR and instance-id.sh (agmsg_pid_start_token, _agmsg_pid_alive).

_agmsg_hp_path() {
  case "$1" in ''|*[!0-9A-Za-z_-]*) return 1 ;; esac
  printf '%s/run/headless-sid.%s' "$SKILL_DIR" "$1"
}

# Publish <sid> -> <team>, owned by the calling process ($$). Atomic, mode 0600,
# refuses a symlink at the destination.
agmsg_headless_provenance_publish() {
  local sid="$1" team="$2" path tmp start
  path="$(_agmsg_hp_path "$sid")" || return 1
  [ -n "$team" ] || return 1
  [ ! -L "$path" ] || return 1
  start="$(agmsg_pid_start_token "$$" 2>/dev/null || true)"
  mkdir -p "$SKILL_DIR/run" 2>/dev/null || return 1
  tmp="$path.tmp.$$"
  ( umask 077
    printf 'team=%s\npid=%s\nstart=%s\n' "$team" "$$" "$start" > "$tmp" ) || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# Remove <sid>'s record only if this process still owns it, so an old owner's
# cleanup cannot delete the record a restarted bridge published since.
agmsg_headless_provenance_remove() {
  local sid="$1" path pid
  path="$(_agmsg_hp_path "$sid")" || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  pid="$(sed -n 's/^pid=//p' "$path" 2>/dev/null | head -1)"
  [ "$pid" = "$$" ] && rm -f "$path" 2>/dev/null
  return 0
}

# 0 when <sid> has a record for exactly <team> whose owner is a live process of
# the same generation. Everything else (missing, unreadable, other team, dead or
# recycled owner, symlink) is "no".
agmsg_headless_provenance_allows() {
  local sid="$1" team="$2" path rec_team rec_pid rec_start now_start
  path="$(_agmsg_hp_path "$sid")" || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  rec_team="$(sed -n 's/^team=//p' "$path" 2>/dev/null | head -1)"
  rec_pid="$(sed -n 's/^pid=//p' "$path" 2>/dev/null | head -1)"
  rec_start="$(sed -n 's/^start=//p' "$path" 2>/dev/null | head -1)"
  [ -n "$rec_team" ] && [ "$rec_team" = "$team" ] || return 1
  case "$rec_pid" in ''|*[!0-9]*) return 1 ;; esac
  _agmsg_pid_alive "$rec_pid" || return 1
  if [ -n "$rec_start" ]; then
    now_start="$(agmsg_pid_start_token "$rec_pid" 2>/dev/null || true)"
    [ -n "$now_start" ] && [ "$now_start" = "$rec_start" ] || return 1
  fi
  return 0
}
