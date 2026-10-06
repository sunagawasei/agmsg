#!/usr/bin/env bats

# Contract test: who may name, decode or classify a host session team.
#
# Naming a session team from an id (axis A) and decoding a team from a record name
# (axis B) are cheap; what a caller then does with the team is what matters. A
# caller that touches ANOTHER session's state (reads and marks an inbox read,
# tombstones, snapshots or despawns a worker) must have asked
# agmsg_session_team_class first (axis C), because a project team may merely share
# a session team's name. This lists every caller of each axis so that adding or
# removing one fails here and has to be classified:
#
#   (i)  own identity only -- registers/subscribes/spawns into the caller's own
#        session team; the join marker mode, or agmsg_session_team_name (which
#        applies the class check itself), keeps a name collision out
#   (ii) touches other state -- must be in the class-checking list below
#
# A name-pattern grep ("s-", "cur-") does not find these; the callers of the
# functions do. Re-run this enumeration when adding a host or a consumer.

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

callers() {  # callers <function-name-regexp>  -> sorted unique relative paths
  (cd "$SCRIPTS" && grep -rlE "$1" . 2>/dev/null | grep -v '^./lib/session-team.sh$' | sed 's|^\./||' | sort -u)
}

@test "axis C: every caller that touches other sessions' state checks the team class" {
  run callers 'agmsg_session_team_class'
  [ "$status" -eq 0 ]
  [ "$output" = "check-inbox.sh
lib/inbox-target.sh
lib/pending-teardown.sh
send.sh
session-end-worker.sh
session-end.sh
watchdog.sh
whoami.sh" ]
}

@test "axis A: callers that name a team from an id" {
  run callers 'agmsg_session_team_name_from_id|agmsg_session_team_name([^_a-z]|$)|agmsg_session_resolve|agmsg_session_hook_team'
  [ "$status" -eq 0 ]
  # (i) own identity: ensure-headless.sh spawn.sh delivery.sh session-start.sh whoami.sh
  # (ii) other state, each also in the class list above: check-inbox.sh
  #      lib/inbox-target.sh lib/pending-teardown.sh send.sh session-end.sh session-end-worker.sh
  [ "$output" = "check-inbox.sh
delivery.sh
ensure-headless.sh
lib/inbox-target.sh
lib/pending-teardown.sh
send.sh
session-end-worker.sh
session-end.sh
session-start.sh
spawn.sh
whoami.sh" ]
}

@test "axis B: callers that decode a team from a record name" {
  run callers 'agmsg_session_team_decode'
  [ "$status" -eq 0 ]
  # lib/pending-teardown.sh (ii) is in the class list above
  [ "$output" = "lib/pending-teardown.sh" ]
}

@test "the readers of a session's inbox share one class-checked resolver" {
  # check-inbox.sh and cursor/inject-watch.sh both resolve through
  # agmsg_inbox_target, which refuses an untrusted session team itself.
  grep -q 'agmsg_session_team_class' "$SCRIPTS/lib/inbox-target.sh"
  grep -q 'inbox-target.sh' "$SCRIPTS/drivers/types/cursor/inject-watch.sh"
}
