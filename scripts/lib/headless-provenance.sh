#!/usr/bin/env bash
# headless-provenance.sh — a headless claude-code worker's own session id, bound
# to the team its bridge serves.
#
# Why: claude re-exports the worker's own session id into every Bash tool it runs
# on a --resume turn, so the worker's send.sh sees a session id that is not the
# session team's. send.sh's cross-session guard would then refuse the worker's
# legitimate reply to its own team. The bridge (the only party that knows which
# team it serves) publishes run/headless-sid.<sid>.<bridge pid> for each turn;
# send.sh accepts a send only when the caller's sid has a live record for exactly
# the destination team. A record names its bridge process by pid and start token,
# so a stale record left by a crashed bridge, or a recycled pid, authorizes
# nothing, and a record without a start token is never published or accepted.
# Each owner writes and removes only its own file (the pid is in the name), so a
# restarted bridge's record can never be deleted by an old owner's cleanup, and a
# reader parses one snapshot of each file. This stops accidental cross-team
# sends; it is not an authentication boundary (any process of the same user can
# write run/).
#
# Requires SKILL_DIR and instance-id.sh (agmsg_pid_start_token, _agmsg_pid_alive).

_agmsg_hp_prefix() {
  case "$1" in ''|*[!0-9A-Za-z_-]*) return 1 ;; esac
  printf '%s/run/headless-sid.%s.' "$SKILL_DIR" "$1"
}

# Publish <sid> -> <team>, owned by the calling process ($$). The temp file is
# created by mktemp (exclusive, mode 0600, unpredictable name), so nothing
# planted at a guessable path is followed; the final name carries our pid.
agmsg_headless_provenance_publish() {
  local sid="$1" team="$2" prefix start tmp
  prefix="$(_agmsg_hp_prefix "$sid")" || return 1
  [ -n "$team" ] || return 1
  start="$(agmsg_pid_start_token "$$" 2>/dev/null || true)"
  [ -n "$start" ] || return 1
  mkdir -p "$SKILL_DIR/run" 2>/dev/null || return 1
  tmp="$(mktemp "$SKILL_DIR/run/.headless-sid.XXXXXX" 2>/dev/null)" || return 1
  if ! printf 'team=%s\npid=%s\nstart=%s\n' "$team" "$$" "$start" > "$tmp" \
      || ! mv -f "$tmp" "$prefix$$"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

# Remove this process's own record for <sid>.
agmsg_headless_provenance_remove() {
  local prefix
  prefix="$(_agmsg_hp_prefix "$1")" || return 0
  rm -f "$prefix$$" 2>/dev/null || true
  return 0
}

# 0 when <sid> has a record for exactly <team> whose owner is a live process of
# the same generation. Everything else (missing, unreadable, other team, no start
# token, dead or recycled owner, symlink) is "no".
agmsg_headless_provenance_allows() {
  local sid="$1" team="$2" prefix f rec rec_team rec_pid rec_start now_start
  local found="" other=0
  prefix="$(_agmsg_hp_prefix "$sid")" || return 1
  for f in "$prefix"[0-9]*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    rec="$(cat "$f" 2>/dev/null)" || continue
    rec_team="$(printf '%s\n' "$rec" | sed -n 's/^team=//p' | head -1)"
    rec_pid="$(printf '%s\n' "$rec" | sed -n 's/^pid=//p' | head -1)"
    rec_start="$(printf '%s\n' "$rec" | sed -n 's/^start=//p' | head -1)"
    [ -n "$rec_team" ] || continue
    case "$rec_pid" in ''|*[!0-9]*) continue ;; esac
    [ "$f" = "$prefix$rec_pid" ] || continue
    [ -n "$rec_start" ] || continue
    _agmsg_pid_alive "$rec_pid" || continue
    now_start="$(agmsg_pid_start_token "$rec_pid" 2>/dev/null || true)"
    [ -n "$now_start" ] && [ "$now_start" = "$rec_start" ] || continue
    # A live record for this sid. The sid is bound to ONE team: live records
    # that name different teams make it ambiguous and authorize nothing.
    if [ "$rec_team" = "$team" ]; then found=1; else other=1; fi
  done
  [ -n "$found" ] && [ "$other" -eq 0 ]
}
