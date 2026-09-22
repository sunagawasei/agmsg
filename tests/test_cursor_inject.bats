#!/usr/bin/env bats

# cursor's injection watcher (scripts/drivers/types/cursor/inject-watch.sh):
# a non-consuming id-tagged fetch/ack loop that pushes messages into a herdr
# pane via `herdr agent prompt`, plus its teardown wiring in session-end.sh
# and delivery.sh. herdr is always a stub here — see herdr-stub.sh below and
# [subtask:D]'s packet: this suite must never touch a real herdr pane.

load test_helper

setup() {
  setup_test_env
  # Never let a real herdr binary/pane leak into these tests, even by
  # accident: every invocation in this file goes through AGMSG_HERDR_CMD.
  unset HERDR_PANE_ID HERDR_ENV
  # An ambient AGMSG_CURSOR_BRIDGE (e.g. inherited from bats' own launching
  # shell) would make the env-propagation tests' positive assertions vacuous
  # -- they'd pass even if _spawn.sh's export were removed entirely. The
  # negative control explicitly does `env -u AGMSG_CURSOR_BRIDGE`, so it is
  # unaffected by this.
  unset AGMSG_CURSOR_BRIDGE
  export TEST_PROJECT="$(mktemp -d)"
  export TEAM="team"
  export AGENT="claude"
  export DB="$TEST_SKILL_DIR/db/messages.db"
  export RUN_DIR="$TEST_SKILL_DIR/run"
  bash "$SCRIPTS/join.sh" "$TEAM" "$AGENT" cursor "$TEST_PROJECT" >/dev/null

  HERDR_LOG="$TEST_SKILL_DIR/herdr.log"
  : > "$HERDR_LOG"
  HERDR_LIST_JSON="$TEST_SKILL_DIR/herdr-list.json"
  HERDR_STUB="$TEST_SKILL_DIR/herdr-stub.sh"
  cat > "$HERDR_STUB" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'CALL: %s\n' "$*" >> "${AGMSG_TEST_HERDR_LOG:-/dev/null}"
case "$1 $2" in
  "agent list")
    if [ -n "${AGMSG_TEST_HERDR_LIST_BARRIER:-}" ]; then
      : > "${AGMSG_TEST_HERDR_LIST_BARRIER}.reached"
      while [ ! -e "${AGMSG_TEST_HERDR_LIST_BARRIER}.release" ]; do sleep 0.02; done
    fi
    cat "${AGMSG_TEST_HERDR_LIST_JSON:?missing list json}"
    ;;
  "agent prompt")
    if [ -n "${AGMSG_TEST_HERDR_PROMPT_BARRIER:-}" ]; then
      : > "${AGMSG_TEST_HERDR_PROMPT_BARRIER}.reached"
      while [ ! -e "${AGMSG_TEST_HERDR_PROMPT_BARRIER}.release" ]; do sleep 0.02; done
    fi
    exit "${AGMSG_TEST_HERDR_PROMPT_RC:-0}"
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$HERDR_STUB"

  export AGMSG_HERDR_CMD="$HERDR_STUB"
  export AGMSG_TEST_HERDR_LOG="$HERDR_LOG"
  export AGMSG_TEST_HERDR_LIST_JSON="$HERDR_LIST_JSON"
  export AGMSG_INJECT_POLL_INTERVAL=0.1

  # Pre-resolve python3 for inject-watch.sh's owner/lease bootstrap (process-
  # identity.sh via process-owner-launch.sh): skips resolve_python()'s
  # multi-candidate probing loop, the same seam test_process_owner.bats uses.
  AGMSG_TEST_PROCESS_PYTHON="$(command -v python3 2>/dev/null || true)"
  [ -n "$AGMSG_TEST_PROCESS_PYTHON" ] && export AGMSG_TEST_PROCESS_PYTHON

  # A poll cycle here does several subprocess spawns (whoami/inbox/sqlite/herdr
  # stub); under `bats -j 8` those queue behind other tests' subprocesses, so
  # the default 10s wait budget is tight even though an uncontended run clears
  # one in ~2s. Generous, not tuned to a measured worst case.
  #
  # 60s, not 30s: inject-watch.sh now bootstraps through process-identity.sh's
  # owner/lease protocol (process-owner-launch.sh -> python) on every start,
  # adding real, measured startup latency (~1.3s uncontended) on top of the
  # poll-cycle cost above; several tests here start it more than once; and
  # whoami.sh's own target-resolution latency is independently variable under
  # load (observed multi-second stalls in direct repro under -j 8).
  _WAIT_TIMEOUT=60

  _INJECT_PIDS=()
}

teardown() {
  local pid
  for pid in "${_INJECT_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
  done
  # The ack-DB-write-failure test leaves messages.db chmod 444 if it fails
  # before restoring it; harmless for teardown_test_env's rm -rf (unlinking
  # only needs directory write permission), but restore anyway so nothing
  # about this test's failure mode surprises whatever runs next.
  chmod -R u+w "$TEST_SKILL_DIR/db" 2>/dev/null || true
  # Release any barrier a test left blocked, so its stub subprocess (now
  # orphaned once its parent was killed above) doesn't spin forever.
  for f in "$TEST_SKILL_DIR"/*.barrier; do
    [ -e "$f" ] && : > "$f.release"
  done
  # Safety net for the env-propagation test: its own despawn.sh cleanup step
  # never runs if an earlier assertion in that test fails, which would
  # otherwise leak a real detached cursor-bridge.sh process (identity-keyed on
  # team/name, so it collides with the next run of the same test).
  if [ -n "${ENVPROP_PROJECT:-}" ] && [ -f "$RUN_DIR/cursor-bridge.team.cur.pid" ]; then
    kill -9 "$(cat "$RUN_DIR/cursor-bridge.team.cur.pid" 2>/dev/null)" 2>/dev/null || true
  fi
  # Generic safety net for every inject-watch.sh this file's tests may have
  # started: the fast-path test launches one via the real
  # session-start.sh -> _session-start.sh (nohup + disown), so its pid is
  # never added to _INJECT_PIDS above -- without this it outlives
  # teardown_test_env's rm -rf and spins forever polling a herdr-stub config
  # that no longer exists (observed: a dozen-plus of these accumulated across
  # repeated runs and measurably loaded the host).
  for f in "$RUN_DIR"/inject-watch.*.pid; do
    [ -f "$f" ] || continue
    kill -9 "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
  done
  rm -rf "$TEST_PROJECT" "${ENVPROP_PROJECT:-}" "${ENVPROP_PROJECT2:-}"
  teardown_test_env
}

# --- fixtures ---------------------------------------------------------------

pane_json() {  # <pane_id> <status> <cwd> [agent] [terminal_id]
  local pane_id="$1" status="$2" cwd="$3" agent="${4:-cursor}" terminal_id="${5:-}"
  printf '[{"pane_id":"%s","agent":"%s","agent_status":"%s","cwd":"%s","terminal_id":"%s"}]\n' \
    "$pane_id" "$agent" "$status" "$cwd" "$terminal_id"
}

send_msg() {  # <from> <body> -> echoes new message id
  bash "$SCRIPTS/send.sh" "$TEAM" "$1" "$AGENT" "$2" --force >/dev/null
  sqlite3 "$DB" "SELECT max(id) FROM messages;"
}

msg_read_at() { sqlite3 "$DB" "SELECT read_at FROM messages WHERE id=$1;"; }

start_inject() {  # <session_id> <pane_id> <instance_id> [terminal_id]
  bash "$TYPES/cursor/inject-watch.sh" "$1" "$TEST_PROJECT" cursor "$2" "$3" "${4:-}" \
    >"$TEST_SKILL_DIR/inject.$3.out" 2>"$TEST_SKILL_DIR/inject.$3.err" &
  local pid=$!
  _INJECT_PIDS+=("$pid")
  echo "$pid"
}

inject_pidfile() { echo "$RUN_DIR/inject-watch.$1.pid"; }
inject_journal() { echo "$RUN_DIR/inject-watch.$1.journal"; }
inject_resend_pending() { echo "$RUN_DIR/inject-watch.$1.resend-pending"; }

# inject-watch.sh's pidfile appears as soon as process-owner-launch.sh's
# python helper acquires the owner/lease and writes it -- BEFORE the target
# script itself has even started sourcing libraries, let alone installed its
# own TERM/EXIT traps. A signal sent to that pid in this window hits the
# default (untrapped) disposition: the process dies without running its
# cleanup, orphaning the pidfile/owner/lease (found via direct repro: TERM
# sent right at pidfile-appearance left the pidfile behind every time). Wait
# on inject-watch.sh's own .ready sentinel (touched right after its traps are
# installed) instead of the pidfile -- an earlier version of this waited for
# the first herdr call instead, but that call is gated behind whoami.sh's own
# (independently variable, occasionally very slow under load) target
# resolution, which made these three POLL_INTERVAL=60 tests -- only one
# resolution attempt fits in their wait budget -- flaky for a reason that had
# nothing to do with what they're actually testing.
inject_ready_file() { echo "$RUN_DIR/inject-watch.$1.ready"; }
wait_inject_ready() { wait_for_file "$(inject_ready_file "$1")"; }  # <instance_id>

# Mirrors session-end.sh's own instance-id resolution (same libs, same env),
# so a test's expected pidfile name always matches what session-end.sh itself
# computes for the same <session_id> <type>.
compute_instance_id() {
  bash -c '
    SCRIPT_DIR="'"$SCRIPTS"'"
    SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/compat.sh"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/actas-lock.sh"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/resolve-project.sh"
    agmsg_instance_id "$1" "$2"
  ' _ "$1" "$2" 2>/dev/null
}

# PATH with every directory holding an executable "herdr" filtered out, for
# the "herdr binary missing" preflight test — this machine may have a real
# herdr on PATH (it is a real tool used elsewhere in this environment).
path_without_herdr() {
  local dir out=""
  IFS=':' read -ra _dirs <<< "$PATH"
  for dir in "${_dirs[@]}"; do
    [ -x "$dir/herdr" ] && continue
    out="${out:+$out:}$dir"
  done
  printf '%s' "$out"
}

# --- crash recovery ----------------------------------------------------------

@test "kill before injection: message stays unread, then delivers after restart" {
  local sid="sess-a" pane="paneA" iid="iid-a"
  pane_json "$pane" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  local id; id="$(send_msg bob hello-a)"

  local barrier="$TEST_SKILL_DIR/list-a.barrier"
  AGMSG_TEST_HERDR_LIST_BARRIER="$barrier" start_inject "$sid" "$pane" "$iid" >/dev/null
  wait_for_file "$barrier.reached"

  # Fetched and about to check pane status, but journal_write (which happens
  # only after that check passes) has not run yet -- nothing to lose.
  [ -z "$(cat "$(inject_journal "$iid")" 2>/dev/null)" ]
  [ -z "$(msg_read_at "$id")" ]

  kill -9 "${_INJECT_PIDS[-1]}"
  : > "$barrier.release"
  rm -f "$(inject_pidfile "$iid")"
  [ -z "$(msg_read_at "$id")" ]  # still not lost after the crash

  unset AGMSG_TEST_HERDR_LIST_BARRIER
  start_inject "$sid" "$pane" "$iid" >/dev/null
  wait_until 60 _wait_read_at "$id"
  [ -n "$(msg_read_at "$id")" ]
  run grep -c '(再送)' "$HERDR_LOG"
  [ "$output" = "0" ]  # never in flight before the crash, so no resend disclosure
}

_wait_read_at() { [ -n "$(msg_read_at "$1")" ]; }

@test "kill after injection, before ack: restart re-injects with a resend header" {
  local sid="sess-b" pane="paneB" iid="iid-b"
  pane_json "$pane" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  local id; id="$(send_msg bob hello-b)"

  local barrier="$TEST_SKILL_DIR/prompt-b.barrier"
  AGMSG_TEST_HERDR_PROMPT_BARRIER="$barrier" start_inject "$sid" "$pane" "$iid" >/dev/null
  wait_for_file "$barrier.reached"

  # journal_write runs before the herdr call, so the in-flight record exists
  # even though herdr hasn't returned yet.
  run cat "$(inject_journal "$iid")"
  [[ "$output" == "$id"$'\t'* ]]

  kill -9 "${_INJECT_PIDS[-1]}"
  : > "$barrier.release"
  rm -f "$(inject_pidfile "$iid")"
  [ -z "$(msg_read_at "$id")" ]

  : > "$HERDR_LOG"
  unset AGMSG_TEST_HERDR_PROMPT_BARRIER
  start_inject "$sid" "$pane" "$iid" >/dev/null
  wait_until 60 _wait_read_at "$id"
  run grep -c '(再送)' "$HERDR_LOG"
  [ "$output" != "0" ]
}

# --- retry / give-up ---------------------------------------------------------

@test "herdr prompt failure: retry count is monotonic, giving up at exactly RETRY_LIMIT" {
  local sid="sess-c" pane="paneC" iid="iid-c"
  pane_json "$pane" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  local id; id="$(send_msg bob hello-c)"

  # RETRY_LIMIT=5, not 2: with a limit of 2, retry_journal's own processing
  # can reach the limit (and ack the id, so it drops out of poll_new's
  # unread scan) before poll_new gets a chance to re-discover the still-
  # unread id and reset its retry count to 0 in the same cycle -- exactly the
  # bug this hides (found in review: poll_new always passed retry=0, so the
  # count never climbed past ~1 with a higher limit and the id retried
  # forever instead of giving up).
  AGMSG_TEST_HERDR_PROMPT_RC=1 AGMSG_INJECT_RETRY_LIMIT=5 start_inject "$sid" "$pane" "$iid" >/dev/null
  # 5 sequential poll cycles, not 1, each resolving its target via whoami.sh --
  # this file's default 45s budget is sized for a single cycle under `-j 8`
  # contention (see setup()'s _WAIT_TIMEOUT comment) and whoami.sh's own
  # latency is independently variable under load (observed multi-second
  # stalls in direct repro), so this needs more than 5x that single-cycle
  # budget to stay clear of both sources at once.
  wait_until 90 _wait_read_at "$id"

  run sqlite3 "$DB" "SELECT body FROM messages WHERE team='$TEAM' AND from_agent='$AGENT' AND to_agent='bob' AND body LIKE '[inject-error]%';"
  [ -n "$output" ]

  # Exactly RETRY_LIMIT prompt attempts is the signature of a monotonically
  # increasing per-id count; a reset-to-zero regression keeps retrying well
  # past this count instead of giving up here.
  run grep -c 'agent prompt' "$HERDR_LOG"
  [ "$output" = "5" ]
}

_resend_pending_has_id() {  # <iid> <id>
  local f; f="$(inject_resend_pending "$1")"
  [ -f "$f" ] && grep -qxF "$2" "$f"
}

@test "ack DB write failure: stays in-flight (not lost), then resent with a resend disclosure once the DB recovers" {
  local sid="sess-ackfail" pane="paneAckFail" iid="iid-ackfail"
  pane_json "$pane" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  local id; id="$(send_msg bob hello-ackfail)"

  # Read-only DB: inbox.sh's --format ids SELECT still succeeds, but its
  # --mark-read-ids UPDATE cannot -- and inbox.sh swallows that failure and
  # always exits 0 (scripts/inbox.sh), so read_at staying NULL is the only
  # observable symptom of a failed ack.
  chmod 444 "$DB"
  start_inject "$sid" "$pane" "$iid" >/dev/null
  # Wait for the ack failure to actually be RECORDED (RESEND_PENDING holds
  # this id), not just for a first herdr call to appear -- under load, a slow
  # first attempt could still be in flight when this test flips the DB back
  # to writable, in which case that attempt's own ack succeeds on the first
  # try and no resend disclosure is ever produced (found by direct repro
  # under `-j 8`: the test flaked on the resend assertion, not on read_at).
  wait_until 60 _resend_pending_has_id "$iid" "$id"
  [ -z "$(msg_read_at "$id")" ]                            # ack never took
  [ -n "$(cat "$(inject_journal "$iid")" 2>/dev/null)" ]   # still in-flight, not dropped

  # Recovery: chmod alone is not enough. SQLite's WAL mode, on discovering the
  # main db file read-only, creates -shm/-wal sidecars that are THEMSELVES
  # read-only (independent of the main file's own mode) -- chmod 644 on just
  # messages.db leaves those behind and every write keeps failing (found by
  # direct repro: chmod 644 alone did not recover the ack).
  chmod 644 "$DB" "$DB"-wal "$DB"-shm 2>/dev/null || true
  wait_until 60 _wait_read_at "$id"
  run grep -c '(再送)' "$HERDR_LOG"
  [ "$output" != "0" ]  # the retry after recovery discloses the possible duplicate
}

@test "[inject-error] send failure at the retry limit: original message is not acked, retried instead" {
  local sid="sess-notifyfail" pane="paneNotifyFail" iid="iid-notifyfail"
  pane_json "$pane" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  local id; id="$(send_msg bob hello-notifyfail)"

  # Break send.sh so the [inject-error] notice can never go out (mirrors
  # test_cursor_bridge.bats's break_send() convention for the same failure).
  cp "$SCRIPTS/send.sh" "$SCRIPTS/send.sh.orig"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SCRIPTS/send.sh"

  AGMSG_TEST_HERDR_PROMPT_RC=1 AGMSG_INJECT_RETRY_LIMIT=2 start_inject "$sid" "$pane" "$iid" >/dev/null
  sleep 1  # several poll cycles past the retry limit at 0.1s
  [ -z "$(msg_read_at "$id")" ]  # losing the notice must not also lose the message

  mv "$SCRIPTS/send.sh.orig" "$SCRIPTS/send.sh"
  wait_until 60 _wait_read_at "$id"
  run sqlite3 "$DB" "SELECT body FROM messages WHERE team='$TEAM' AND from_agent='$AGENT' AND to_agent='bob' AND body LIKE '[inject-error]%';"
  [ -n "$output" ]
}

# --- pane eligibility ---------------------------------------------------------

@test "pane busy (working/blocked): no injection until idle or done" {
  local sid="sess-d" pane="paneD" iid="iid-d"
  pane_json "$pane" working "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  local id; id="$(send_msg bob hello-d)"

  start_inject "$sid" "$pane" "$iid" >/dev/null
  sleep 0.5  # several poll cycles at 0.1s; asserting absence cannot be polled for
  [ -z "$(msg_read_at "$id")" ]
  run grep -c 'agent prompt' "$HERDR_LOG"
  [ "$output" = "0" ]

  pane_json "$pane" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  wait_until 60 _wait_read_at "$id"
}

@test "pane id reuse (same pane id, different project cwd): never injects" {
  local sid="sess-e" pane="paneE" iid="iid-e"
  pane_json "$pane" idle "/some/other/project" > "$HERDR_LIST_JSON"
  local id; id="$(send_msg bob hello-e)"

  start_inject "$sid" "$pane" "$iid" >/dev/null
  sleep 0.5
  [ -z "$(msg_read_at "$id")" ]
  run grep -c 'agent prompt' "$HERDR_LOG"
  [ "$output" = "0" ]
}

@test "pane id reuse (same pane id, same cwd, same terminal_id): still injects" {
  # Positive control for the test below: proves a matching terminal_id lets
  # delivery through, so that test's "never injects" isn't just this check
  # rejecting every launch that carries a terminal_id at all.
  local sid="sess-e1" pane="paneE1" iid="iid-e1"
  pane_json "$pane" idle "$TEST_PROJECT" cursor "terminal-1" > "$HERDR_LIST_JSON"
  local id; id="$(send_msg bob hello-e1)"

  start_inject "$sid" "$pane" "$iid" "terminal-1" >/dev/null
  wait_until 60 _wait_read_at "$id"
}

@test "pane id reuse (same pane id, same cwd, different terminal_id): never injects" {
  # The dangerous case review flagged: the test above only covers a DIFFERENT
  # cwd, which pane_id/agent/cwd alone already catch. Here everything BUT the
  # terminal_id matches -- exactly what a pane_id recycled for an unrelated
  # new session in the SAME project looks like from herdr's own agent_info
  # (pane_id names the layout slot; terminal_id names the attached process).
  local sid="sess-e2" pane="paneE2" iid="iid-e2"
  pane_json "$pane" idle "$TEST_PROJECT" cursor "terminal-NEW" > "$HERDR_LIST_JSON"
  local id; id="$(send_msg bob hello-e2)"

  start_inject "$sid" "$pane" "$iid" "terminal-OLD" >/dev/null
  sleep 0.5
  [ -z "$(msg_read_at "$id")" ]
  run grep -c 'agent prompt' "$HERDR_LOG"
  [ "$output" = "0" ]
}

# --- both-mode double-delivery guard -----------------------------------------

@test "both mode: an id already marked read by the stop hook is dropped, never injected" {
  local sid="sess-f" pane="paneF" iid="iid-f"
  pane_json "$pane" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  local id; id="$(send_msg bob hello-f)"
  sqlite3 "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=$id;"

  mkdir -p "$RUN_DIR"
  printf '%s\t%s\t%s\t0\n' "$id" "$TEAM" "$AGENT" > "$(inject_journal "$iid")"

  start_inject "$sid" "$pane" "$iid" >/dev/null
  wait_for_missing "$(inject_journal "$iid")"
  run cat "$HERDR_LOG"
  [ -z "$output" ]  # dropped before ever consulting herdr
}

# --- lifecycle: pidfile ownership + teardown wiring --------------------------

@test "session-end.sh stops this session's inject watcher and removes its pidfile" {
  local sid="sess-g" pane="paneG"
  local iid; iid="$(compute_instance_id "$sid" cursor)"
  pane_json "$pane" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  AGMSG_INJECT_POLL_INTERVAL=60 start_inject "$sid" "$pane" "$iid" >/dev/null
  wait_inject_ready "$iid"
  local pid; pid="$(cat "$(inject_pidfile "$iid")")"

  printf '{"session_id":"%s"}' "$sid" | bash "$SCRIPTS/session-end.sh" cursor "$TEST_PROJECT" >/dev/null

  wait_for_missing "$(inject_pidfile "$iid")"
  wait_for_pid_exit "$pid"
}

@test "delivery set off stops the inject watcher and removes its pidfile" {
  local sid="sess-h" pane="paneH" iid="iid-h"
  pane_json "$pane" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  AGMSG_INJECT_POLL_INTERVAL=60 start_inject "$sid" "$pane" "$iid" >/dev/null
  wait_inject_ready "$iid"
  local pid; pid="$(cat "$(inject_pidfile "$iid")")"

  bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT" >/dev/null

  wait_for_missing "$(inject_pidfile "$iid")"
  wait_for_pid_exit "$pid"
}

@test "delivery set turn stops the inject watcher and removes its pidfile" {
  local sid="sess-i" pane="paneI" iid="iid-i"
  pane_json "$pane" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  AGMSG_INJECT_POLL_INTERVAL=60 start_inject "$sid" "$pane" "$iid" >/dev/null
  wait_inject_ready "$iid"
  local pid; pid="$(cat "$(inject_pidfile "$iid")")"

  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT" >/dev/null

  wait_for_missing "$(inject_pidfile "$iid")"
  wait_for_pid_exit "$pid"
}

# --- lifecycle: ps-independent, PID-reuse-safe ownership (review findings) ---

# PATH with `ps` -- and only `ps` -- missing. Reproduces the review finding
# directly: the old cmdline-substring dedup (compat_get_cmdline -> `ps -o
# args=`) made `delivery set off|turn` time out in a sandbox without `ps`; the
# owner/lease check this file now uses needs no `ps` call in the owned case at
# all. Dropping the whole directory would take rm/cat/sleep/date with it (`ps`
# is /bin/ps on macOS), so the script would die on those instead of on `ps`.
path_without_ps() {
  local dir entry out="" mirror i=0
  IFS=':' read -ra _dirs <<< "$PATH"
  for dir in "${_dirs[@]}"; do
    if [ -x "$dir/ps" ]; then
      mirror="$TEST_SKILL_DIR/nops.$i"
      i=$((i + 1))
      mkdir -p "$mirror"
      for entry in "$dir"/*; do
        [ -e "$entry" ] || continue
        [ "${entry##*/}" = ps ] && continue
        ln -sf "$entry" "$mirror/${entry##*/}"
      done
      dir="$mirror"
    fi
    out="${out:+$out:}$dir"
  done
  printf '%s' "$out"
}

@test "delivery set off stops the inject watcher even with no ps on PATH" {
  local sid="sess-nops" pane="paneNoPs" iid="iid-nops"
  pane_json "$pane" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  AGMSG_INJECT_POLL_INTERVAL=60 start_inject "$sid" "$pane" "$iid" >/dev/null
  wait_inject_ready "$iid"
  local pid; pid="$(cat "$(inject_pidfile "$iid")")"

  run env PATH="$(path_without_ps)" bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT"
  [ "$status" -eq 0 ]

  wait_for_missing "$(inject_pidfile "$iid")"
  wait_for_pid_exit "$pid"
}

@test "delivery stop (bare) also stops cursor's inject watcher" {
  local sid="sess-stop" pane="paneStop" iid="iid-stop"
  pane_json "$pane" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  AGMSG_INJECT_POLL_INTERVAL=60 start_inject "$sid" "$pane" "$iid" >/dev/null
  wait_inject_ready "$iid"
  local pid; pid="$(cat "$(inject_pidfile "$iid")")"

  run bash "$SCRIPTS/delivery.sh" stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"inject watcher"* ]]

  wait_for_missing "$(inject_pidfile "$iid")"
  wait_for_pid_exit "$pid"
}

@test "delivery restart <type> <project> also stops cursor's inject watcher" {
  local sid="sess-restart" pane="paneRestart" iid="iid-restart"
  pane_json "$pane" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"
  AGMSG_INJECT_POLL_INTERVAL=60 start_inject "$sid" "$pane" "$iid" >/dev/null
  wait_inject_ready "$iid"
  local pid; pid="$(cat "$(inject_pidfile "$iid")")"

  run bash "$SCRIPTS/delivery.sh" restart cursor "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"inject watcher"* ]]

  wait_for_missing "$(inject_pidfile "$iid")"
  wait_for_pid_exit "$pid"
}

@test "session-end.sh does not kill an unrelated process that reused the pidfile's PID" {
  local sid="sess-reuse"
  local iid; iid="$(compute_instance_id "$sid" cursor)"

  # A live process standing in for "whatever the OS handed this PID to after
  # inject-watch.sh already exited" -- no owner sidecar names it, which is
  # exactly the state a recycled PID leaves behind.
  test_fixture_start_reaped_process sleep 300
  local unrelated_pid="$TEST_REAPED_PID"
  mkdir -p "$RUN_DIR"
  printf '%s\n' "$unrelated_pid" > "$(inject_pidfile "$iid")"

  printf '{"session_id":"%s"}' "$sid" | bash "$SCRIPTS/session-end.sh" cursor "$TEST_PROJECT" >/dev/null

  sleep 0.5  # absence can't be polled for; give session-end.sh's sync section time to act
  kill -0 "$unrelated_pid" 2>/dev/null  # still alive: session-end.sh did not touch it
  # test_fixture_cleanup (via teardown_test_env) reaps this fixture pid; no
  # manual cleanup needed here.
}

# --- delivery.sh preflight ordering -------------------------------------------

@test "delivery set monitor without herdr on PATH: exits non-zero, hooks.json untouched" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT" >/dev/null
  local hooks_file="$TEST_PROJECT/.cursor/hooks.json"
  local before; before="$(cat "$hooks_file")"

  run env PATH="$(path_without_herdr)" bash "$SCRIPTS/delivery.sh" set monitor cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ "$(cat "$hooks_file")" = "$before" ]
}

@test "delivery set both without herdr on PATH: exits non-zero, hooks.json untouched" {
  local hooks_file="$TEST_PROJECT/.cursor/hooks.json"
  [ ! -e "$hooks_file" ]

  run env PATH="$(path_without_herdr)" bash "$SCRIPTS/delivery.sh" set both cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ ! -e "$hooks_file" ]
}

# --- session-start.sh integration (_session-start.sh's three extension points) --

# session-start.sh's fast path requires a resolvable, stable agent pid (its
# gate keys cc-instance.<pid> lookups on it) -- under setup_test_env's default
# AGMSG_AGENT_PID="" that lookup can never succeed, so this is the one test in
# this file that binds a real (fixture) owner pid instead.
fire_session_start() {  # <session_id>
  printf '{"session_id":"%s"}' "$1" | bash "$SCRIPTS/session-start.sh" cursor "$TEST_PROJECT"
}

# GNU form first, BSD fallback -- this file's own test seam, not
# lib/compat.sh's compat_file_mtime: under `nix develop` on macOS, nix's
# coreutils stat shadows the system one, so compat_file_mtime's Darwin branch
# (`stat -f %m`, BSD-only) fails here even though production code runs fine
# under the real host shell it targets.
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

@test "fast path: first beforeSubmitPrompt call takes the full GC pass, second skips it" {
  agmsg_test_start_session_owner
  local sid="sess-fp"
  pane_json "paneFP" idle "$TEST_PROJECT" > "$HERDR_LIST_JSON"

  run fire_session_start "$sid"
  [ "$status" -eq 0 ]
  local iid; iid="$(compute_instance_id "$sid" cursor)"
  wait_for_file "$(inject_pidfile "$iid")"

  # cc-instance.<pid> is written only by the full path (session-start.sh's
  # agmsg_session_start_common_init); a fast-path call reads it but never
  # rewrites it. Comparing its mtime across calls -- not the pidfile's own
  # mtime -- is what actually distinguishes "took the full pass" from "reused
  # what the first call already set up", per the packet's own suggestion.
  local cc_instance="$RUN_DIR/cc-instance.$AGMSG_TEST_OWNER_PID"
  [ -f "$cc_instance" ]  # first call took the full path (this file only exists after it)
  local before; before="$(_mtime "$cc_instance")"

  sleep 1.1  # mtime has 1s resolution; must exceed it to catch a rewrite

  run fire_session_start "$sid"
  [ "$status" -eq 0 ]
  local after; after="$(_mtime "$cc_instance")"
  [ "$after" = "$before" ]  # second call: fast path, no rewrite

  agmsg_test_stop_session_owner
}

# --- cursor worker env propagation (AGMSG_CURSOR_BRIDGE) ---------------------
#
# Subject differs from the rest of this file: inject-watch.sh's interactive
# monitor watcher never sets AGMSG_CURSOR_BRIDGE (that's the headless
# read-only-reviewer worker, scripts/drivers/types/cursor/_spawn.sh +
# cursor-bridge.sh, out of this subtask's file set). Placed here per
# [task:cursor-main-parity]'s test item because it observes that subsystem
# without modifying it.
#
# Runs the REAL spawn.sh --headless -> process-owner-launch.sh ->
# cursor-bridge.sh chain (only cursor-agent itself is a stub, via PATH), so the
# stub is the only thing standing in for what a real hook runtime would do:
# _spawn.sh's own comment on agmsg_spawn_headless documents this as
# "create-chat, the bridge process, and every turn it runs" needing
# AGMSG_CURSOR_BRIDGE visible. The stub, when invoked as a turn (`-p`), reads
# the real .cursor/hooks.json this test wrote via delivery.sh and runs its
# `stop` command itself -- i.e. it plays the part of cursor-agent's own hook
# dispatch, per the packet's "スタブが実際にフックコマンドを起動する" instruction.
#
# That first test alone can't isolate process-owner-launch.sh's re-exec: the
# real cursor-bridge.sh re-exports AGMSG_CURSOR_BRIDGE=1 itself at its own
# startup (:17), so even a re-exec that dropped it would go undetected -- the
# `-p` turn always sees "=1" again regardless. The second test below swaps in
# a fake bridge (AGMSG_CURSOR_BRIDGE_CMD, the same seam test_spawn.bats uses)
# that does NOT re-export, so what it observes is whatever value actually
# survived spawn.sh -> process-owner-launch.sh's self re-exec alone.
# wait_until treats any status > 1 as a hard error (not "not yet"), and grep
# exits 2 (not 1) when the file doesn't exist yet -- so this must not let a
# bare grep exit code reach it before ENVPROP_HOOK_OUT is first created.
_envprop_hook_ran() { [ -f "$ENVPROP_HOOK_OUT" ] && grep -q '^rc=' "$ENVPROP_HOOK_OUT"; }

@test "AGMSG_CURSOR_BRIDGE is visible to the stop hook across create-chat, spawn re-exec, and a bridge turn" {
  export ENVPROP_PROJECT="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" team alice claude-code "$ENVPROP_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set turn cursor "$ENVPROP_PROJECT" >/dev/null

  export ENVPROP_STUB_BIN="$TEST_SKILL_DIR/envprop-stub-bin"
  mkdir -p "$ENVPROP_STUB_BIN"
  export ENVPROP_ENV_LOG="$TEST_SKILL_DIR/envprop-env.log"
  export ENVPROP_HOOK_OUT="$TEST_SKILL_DIR/envprop-hook.out"
  : > "$ENVPROP_ENV_LOG"

  cat > "$ENVPROP_STUB_BIN/cursor-agent" <<'STUB'
#!/usr/bin/env bash
printf 'argv=[%s] AGMSG_CURSOR_BRIDGE=%s\n' "$*" "${AGMSG_CURSOR_BRIDGE:-UNSET}" >> "$ENVPROP_ENV_LOG"
if [ "$1" = create-chat ]; then
  echo "11111111-2222-3333-4444-555555555555"
  exit 0
fi
resume="" workspace="" prev=""
for a in "$@"; do
  [ "$prev" = "--resume" ] && resume="$a"
  [ "$prev" = "--workspace" ] && workspace="$a"
  prev="$a"
done
if [ -n "$workspace" ] && [ -f "$workspace/.cursor/hooks.json" ]; then
  cmd="$(sqlite3 :memory: "SELECT json_extract(readfile('$workspace/.cursor/hooks.json'),'\$.hooks.stop[0].command');")"
  if [ -n "$cmd" ]; then
    bash -c "$cmd" </dev/null >"$ENVPROP_HOOK_OUT" 2>&1
    printf 'rc=%s\n' "$?" >> "$ENVPROP_HOOK_OUT"
  fi
fi
printf '{"type":"system","subtype":"init","apiKeySource":"login","cwd":"/tmp","session_id":"%s","permissionMode":"default"}\n' "$resume"
printf '{"type":"result","subtype":"success","duration_ms":1,"duration_api_ms":1,"is_error":false,"result":"ok","session_id":"%s","request_id":"r1","usage":{"inputTokens":1,"outputTokens":1,"cacheReadTokens":0,"cacheWriteTokens":0}}\n' "$resume"
STUB
  chmod +x "$ENVPROP_STUB_BIN/cursor-agent"

  export PATH="$ENVPROP_STUB_BIN:$PATH"
  export AGMSG_CURSOR_BRIDGE_INTERVAL=1
  run bash "$SCRIPTS/spawn.sh" cursor cur --project "$ENVPROP_PROJECT" --headless
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless cursor reviewer 'cur'"* ]]

  bash "$SCRIPTS/send.sh" team alice cur hello-envprop --force >/dev/null

  wait_until 60 _envprop_hook_ran

  # 1) create-chat saw it.
  run grep -F 'create-chat' "$ENVPROP_ENV_LOG"
  [[ "$output" == *"AGMSG_CURSOR_BRIDGE=1"* ]]

  # 2) the turn invocation (spawn re-exec + bridge's own startup export,
  # jointly -- see the header comment above) saw it.
  run grep -F -- '-p --trust' "$ENVPROP_ENV_LOG"
  [ -n "$output" ]
  [[ "$output" == *"AGMSG_CURSOR_BRIDGE=1"* ]]

  # 3) the stop hook subprocess itself (launched by the stub, not by this
  # test) saw it: check-inbox.sh's guard exits 0 before ever touching its
  # cooldown marker, so the marker's absence is the hook-side evidence.
  run cat "$ENVPROP_HOOK_OUT"
  [[ "$output" == *"rc=0"* ]]
  [ ! -e "$RUN_DIR/.lastcheck-cur" ]

  # Negative control: the same script, same identity, without the guard
  # variable DOES touch the marker -- proving (3) is a real signal, not a
  # marker that was already unreachable for some unrelated reason.
  run env -u AGMSG_CURSOR_BRIDGE bash "$SCRIPTS/check-inbox.sh" cursor "$ENVPROP_PROJECT"
  [ -f "$RUN_DIR/.lastcheck-cur" ]
  rm -f "$RUN_DIR/.lastcheck-cur"

  bash "$SCRIPTS/despawn.sh" team alice cur --force >/dev/null 2>&1 || true
}

_envprop_fake_bridge_log_nonempty() { [ -s "$ENVPROP_BRIDGE_LOG" ]; }

@test "AGMSG_CURSOR_BRIDGE survives spawn.sh's own re-exec into a fake bridge (AGMSG_CURSOR_BRIDGE_CMD)" {
  # Distinct team/name from the test above: the duplicate-worker scan matches
  # by identity key (base64 of team+name) via `ps` machine-wide, not scoped to
  # this test's own $TEST_SKILL_DIR -- reusing team/cur while the other test's
  # real bridge is still up under `bats -j 8` would misreport "already
  # running" and this fake bridge would never launch.
  export ENVPROP_PROJECT2="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" teamfake alice claude-code "$ENVPROP_PROJECT2" >/dev/null

  export ENVPROP_STUB_BIN2="$TEST_SKILL_DIR/envprop-stub-bin2"
  mkdir -p "$ENVPROP_STUB_BIN2"
  export ENVPROP_BRIDGE_LOG="$TEST_SKILL_DIR/envprop-bridge.log"
  : > "$ENVPROP_BRIDGE_LOG"

  cat > "$ENVPROP_STUB_BIN2/cursor-agent" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = create-chat ]; then
  echo "22222222-3333-4444-5555-666666666666"
  exit 0
fi
exit 0
STUB
  chmod +x "$ENVPROP_STUB_BIN2/cursor-agent"

  # A fake bridge that, unlike the real cursor-bridge.sh (:17), does NOT
  # re-export AGMSG_CURSOR_BRIDGE itself -- so the value it observes is
  # whatever spawn.sh's agmsg_spawn_headless export actually carried through
  # process-owner-launch.sh's self re-exec, not a value the bridge restored on
  # its own. Mirrors test_spawn.bats's _make_fake_cursor_headless convention
  # (records to a log, exits immediately; no real cursor turn runs).
  cat > "$ENVPROP_STUB_BIN2/fake-cursor-bridge.sh" <<EOF
#!/usr/bin/env bash
printf 'AGMSG_CURSOR_BRIDGE=%s\n' "\${AGMSG_CURSOR_BRIDGE:-UNSET}" >> "$ENVPROP_BRIDGE_LOG"
exit 0
EOF
  chmod +x "$ENVPROP_STUB_BIN2/fake-cursor-bridge.sh"

  run env AGMSG_CURSOR_AGENT_CMD="$ENVPROP_STUB_BIN2/cursor-agent" \
    AGMSG_CURSOR_BRIDGE_CMD="$ENVPROP_STUB_BIN2/fake-cursor-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" cursor curfake --project "$ENVPROP_PROJECT2" --headless
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless cursor reviewer 'curfake'"* ]]

  wait_until 30 _envprop_fake_bridge_log_nonempty
  run cat "$ENVPROP_BRIDGE_LOG"
  [[ "$output" == *"AGMSG_CURSOR_BRIDGE=1"* ]]
  [[ "$output" != *"UNSET"* ]]
}
