#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  mkdir -p "$SKILL_DIR/run"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/team-config-audit.sh"
}

teardown() {
  teardown_test_env
}

audit_log() {
  printf '%s/run/team-config-audit.log' "$SKILL_DIR"
}

audit_fields() {
  awk -F '\t' '{ print NF }' "$(audit_log)"
}

@test "audit: writes seven columns with UTC timestamp, pid, and caller basename" {
  agmsg_team_config_audit team join alice "created"
  local line caller
  line="$(cat "$(audit_log)")"
  caller="$(basename "$0")"

  [ "$(printf '%s\n' "$line" | awk -F '\t' '{ print NF }')" -eq 7 ]
  [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'\t'[0-9]+$'\t' ]]
  [ "$(printf '%s\n' "$line" | cut -f2)" = "$$" ]
  [ "$(printf '%s\n' "$line" | cut -f3)" = "$caller" ]
  [ "$(printf '%s\n' "$line" | cut -f4-7)" = $'team\tjoin\talice\tcreated' ]
}

@test "audit: accepts only the fixed action vocabulary and documents rename semantics" {
  agmsg_team_config_audit team join alice joined
  agmsg_team_config_audit team leave alice left
  agmsg_team_config_audit team reset alice reset
  agmsg_team_config_audit old-team rename-team "" new-team
  agmsg_team_config_audit team rename-agent old-agent new-agent
  agmsg_team_config_audit team unknown alice ignored

  [ "$(wc -l < "$(audit_log)" | tr -d ' ')" -eq 5 ]
  [ "$(sed -n '4p' "$(audit_log)" | cut -f4-7)" = $'old-team\trename-team\t\tnew-team' ]
  [ "$(sed -n '5p' "$(audit_log)" | cut -f4-7)" = $'team\trename-agent\told-agent\tnew-agent' ]
}

@test "audit: replaces tabs, newlines, CR, and control bytes in every field" {
  local team agent detail line payload
  team=$'T\tone\nT\rtwo\001\033\177'
  agent=$'a\tb\nc\002'
  detail=$'d\te\nf\r\003'
  agmsg_team_config_audit "$team" join "$agent" "$detail"
  line="$(cat "$(audit_log)")"
  payload="$(printf '%s' "$line" | tr -d '\011')"

  [ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(printf '%s\n' "$line" | awk -F '\t' '{ print NF }')" -eq 7 ]
  ! printf '%s' "$payload" | LC_ALL=C grep -q '[[:cntrl:]]'
}

@test "audit: appends in order and keeps the newest detail" {
  agmsg_team_config_audit team join alice first
  agmsg_team_config_audit team leave alice second

  [ "$(wc -l < "$(audit_log)" | tr -d ' ')" -eq 2 ]
  [ "$(tail -n 1 "$(audit_log)" | cut -f7)" = second ]
}

@test "audit: default cap is 5000 newest lines" {
  local log="$(audit_log)" i
  for i in $(seq 1 5000); do
    printf '2026-01-01T00:00:00Z\t1\tseed\tteam\tjoin\tagent\tseed-%s\n' "$i" >> "$log"
  done
  agmsg_team_config_audit team join alice newest

  [ "$(wc -l < "$log" | tr -d ' ')" -eq 5000 ]
  ! grep -q $'seed-1$' "$log"
  grep -q $'newest$' "$log"
}

@test "audit: honors a smaller positive cap for bounded concurrent append tests" {
  export AGMSG_TEAM_CONFIG_AUDIT_CAP=25
  local pids="" i
  for i in $(seq 1 60); do
    (
      agmsg_team_config_audit team join "agent-$i" "detail-$i"
    ) &
    pids="$pids $!"
  done
  for i in $pids; do
    wait "$i" || true
  done
  agmsg_team_config_audit team join sentinel newest-sentinel

  [ "$(wc -l < "$(audit_log)" | tr -d ' ')" -le 25 ]
  grep -q $'newest-sentinel$' "$(audit_log)"
  awk -F '\t' 'NF != 7 { bad=1 } END { exit bad }' "$(audit_log)"
}

@test "audit: concurrent lock contention never rolls back the final append" {
  export AGMSG_TEAM_CONFIG_AUDIT_CAP=10
  local lock="$SKILL_DIR/run/team-config-audit.lock"
  mkdir "$lock"

  run agmsg_team_config_audit team join alice dropped
  [ "$status" -eq 0 ]
  [ ! -f "$(audit_log)" ]
  rmdir "$lock"

  agmsg_team_config_audit team join alice retained
  grep -q $'retained$' "$(audit_log)"
}

@test "audit: run directory, log, and trim failures are best effort" {
  local blocker="$TEST_SKILL_DIR/blocker"
  : > "$blocker"
  run env SKILL_DIR="$blocker" bash -c '
    . "$0"
    agmsg_team_config_audit team join alice blocked
  ' "$SKILL_DIR/scripts/lib/team-config-audit.sh"
  [ "$status" -eq 0 ]

  mkdir -p "$SKILL_DIR/run/team-config-audit.log"
  run agmsg_team_config_audit team join alice log-is-directory
  [ "$status" -eq 0 ]
  rmdir "$SKILL_DIR/run/team-config-audit.log"

  export AGMSG_TEAM_CONFIG_AUDIT_CAP=1
  agmsg_team_config_audit team join alice survives-trim
  [ "$(tail -n 1 "$(audit_log)" | cut -f7)" = survives-trim ]
}
