#!/usr/bin/env bats

# session-end.sh runs inside Claude Code's ~1.5s SessionEnd budget and blocks
# exit while it does. Wall time is load-dependent, so the budget is held as a
# fork count instead: how many subshells and which external commands the
# synchronous part spawns. The worker is a stub so only the hook is measured.

load test_helper

# Subshell ceiling for the hook with a pinned agent pid (no ancestry walk) and
# two spawn records. Measured 2026-10-06 (bash 5): 86 before the builtin rewrite, 39 after; the
# limit is under 60% of the old count.
SUBSHELL_LIMIT=50
# Commands the synchronous part must not fork when AGMSG_AGENT_PID is pinned.
FORBIDDEN_CMDS="sed head grep awk basename cat tr"

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN="$TEST_SKILL_DIR/run"
  export SESSION_ID="budget-session"
  export STEAM="s-$SESSION_ID"
  export PROJ="/tmp/agmsg-session-end-budget"
  mkdir -p "$RUN"
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/actas-lock.sh"
  sleep 300 &
  AGENT_PID=$!
  printf 'pid:%s\t%s\tcodex' "$AGENT_PID" "$PROJ" > "$(agmsg_spawn_path "$STEAM" "codex__one")"
  printf 'pid:%s\t%s\tcursor' "$AGENT_PID" "$PROJ" > "$(agmsg_spawn_path "$STEAM" "カーソル 三")"
  # Worker stub: records what it sees at entry, then waits for release so a
  # test can inspect the state at the moment the hook returned.
  cat > "$SCRIPTS/session-end-worker.sh" <<'STUB'
#!/usr/bin/env bash
RUN="$(cd "$(dirname "$0")/.." && pwd)/run"
{ [ -e "$RUN/watchdog.s-budget-session.tombstone" ] && echo tombstone; [ -s "$5" ] && echo snapshot; } > "$RUN/worker.seen.tmp"
mv "$RUN/worker.seen.tmp" "$RUN/worker.seen"
for _ in $(seq 1 100); do [ -e "$RUN/release" ] && break; sleep 0.1; done
cp "$5" "$RUN/worker.snapshot" 2>/dev/null
touch "$RUN/worker.done"
STUB
  chmod +x "$SCRIPTS/session-end-worker.sh"
}

teardown() {
  kill "$AGENT_PID" 2>/dev/null || true
  wait "$AGENT_PID" 2>/dev/null || true
  touch "$RUN/release"
  teardown_test_env
}

payload() { printf '{"session_id":"%s"}' "$SESSION_ID"; }

# Installs logging shims for the commands in $1 in front of PATH.
install_shims() {
  local cmd real
  mkdir -p "$TEST_SKILL_DIR/shims"
  : > "$TEST_SKILL_DIR/shim.log"
  for cmd in $1; do
    real="$(command -v "$cmd")" || continue
    printf '#!/bin/sh\necho %s >> "%s"\nexec "%s" "$@"\n' "$cmd" "$TEST_SKILL_DIR/shim.log" "$real" > "$TEST_SKILL_DIR/shims/$cmd"
    chmod +x "$TEST_SKILL_DIR/shims/$cmd"
  done
  PATH="$TEST_SKILL_DIR/shims:$PATH"
}

@test "hook forks none of sed/head/grep/awk/basename/cat/tr on the pinned-agent path" {
  install_shims "$FORBIDDEN_CMDS"
  payload | AGMSG_AGENT_PID="$AGENT_PID" bash "$SCRIPTS/session-end.sh" claude-code "$PROJ"
  # Read the log before anything else on this PATH (wait_until, cat) can add to it.
  local forked
  forked="$(<"$TEST_SKILL_DIR/shim.log")"
  [ -z "$forked" ] || { echo "forked: $(echo "$forked" | sort | uniq -c | tr '\n' ' ')"; return 1; }
}

@test "hook spawns at most SUBSHELL_LIMIT subshells on the pinned-agent path" {
  local b=bash
  [ "$(bash -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ] || skip "BASHPID needs bash >= 4"
  payload | AGMSG_AGENT_PID="$AGENT_PID" PS4='@${BASHPID} ' bash -x "$SCRIPTS/session-end.sh" claude-code "$PROJ" 2> "$TEST_SKILL_DIR/trace"
  local n
  n="$(grep -o '^@*[0-9]*' "$TEST_SKILL_DIR/trace" | tr -d @ | sort -u | wc -l | tr -d ' ')"
  echo "subshells=$n limit=$SUBSHELL_LIMIT"
  [ "$n" -le "$SUBSHELL_LIMIT" ]
}

@test "tombstone and snapshot exist when the hook returns, before the worker is released" {
  payload | AGMSG_AGENT_PID="$AGENT_PID" bash "$SCRIPTS/session-end.sh" claude-code "$PROJ"
  [ -s "$RUN/watchdog.$STEAM.tombstone" ]
  wait_until 5 test -e "$RUN/worker.seen"
  [ ! -e "$RUN/worker.done" ]
  [ "$(cat "$RUN/worker.seen")" = "$(printf 'tombstone\nsnapshot')" ]
  touch "$RUN/release"
  wait_until 5 test -e "$RUN/worker.done"
}

@test "snapshot rows carry the decoded worker name and the hook-time record" {
  payload | AGMSG_AGENT_PID="$AGENT_PID" bash "$SCRIPTS/session-end.sh" claude-code "$PROJ"
  touch "$RUN/release"
  wait_until 5 test -e "$RUN/worker.done"
  grep -qxF "$(printf 'codex__one\tpid:%s\t%s\tcodex' "$AGENT_PID" "$PROJ")" "$RUN/worker.snapshot"
  grep -qxF "$(printf 'カーソル 三\tpid:%s\t%s\tcursor' "$AGENT_PID" "$PROJ")" "$RUN/worker.snapshot"
  [ "$(wc -l < "$RUN/worker.snapshot" | tr -d ' ')" -eq 2 ]
}

@test "session_id is taken the way the old sed took it" {
  # one-line, multi-line, last-on-a-line, first matching line, empty first match, none
  local cases=(
    '{"session_id":"one"}|one'
    $'{\n  "cwd": "/x",\n  "session_id" : "multi"\n}|multi'
    '{"session_id":"a","session_id":"b"}|b'
    $'{"x":1}\n{"session_id":"first"}\n{"session_id":"second"}|first'
    $'{"session_id":""}\n{"session_id":"later"}|'
    '{"other":"v"}|'
    $'{"session_id":"crlf"}\r|crlf'
  )
  local c input want
  for c in "${cases[@]}"; do
    input="${c%|*}"; want="${c##*|}"
    rm -f "$RUN"/watchdog.*.tombstone "$RUN/worker.seen"
    printf '%s' "$input" | AGMSG_AGENT_PID="$AGENT_PID" bash "$SCRIPTS/session-end.sh" claude-code "$PROJ"
    if [ "$want" = "" ]; then
      ! compgen -G "$RUN/watchdog.*.tombstone" >/dev/null || { echo "unexpected tombstone for [$input]"; return 1; }
    else
      [ -s "$RUN/watchdog.s-$want.tombstone" ] || { echo "no tombstone for [$input] want $want"; ls "$RUN"; return 1; }
    fi
  done
}

@test "hook starts the worker from an absolute path, ./scripts and from inside scripts/" {
  local i
  for i in abs rel inside; do
    rm -f "$RUN/worker.seen"
    case "$i" in
      abs)    payload | AGMSG_AGENT_PID="$AGENT_PID" bash "$SCRIPTS/session-end.sh" claude-code "$PROJ" ;;
      rel)    (cd "$TEST_SKILL_DIR" && payload | AGMSG_AGENT_PID="$AGENT_PID" bash ./scripts/session-end.sh claude-code "$PROJ") ;;
      inside) (cd "$SCRIPTS" && payload | AGMSG_AGENT_PID="$AGENT_PID" bash session-end.sh claude-code "$PROJ") ;;
    esac
    wait_until 5 test -e "$RUN/worker.seen" || { echo "worker not started via $i"; return 1; }
  done
}
