#!/usr/bin/env bats

# The builtin-only encode/decode and _agmsg_st_conf must return what the awk and
# grep|head versions they replaced returned (the SessionEnd hook budget is why
# they lost their forks). Each reference implementation is copied below; they
# are the oracle, not code under test. Run under both the PATH bash and the
# system bash (3.2 on macOS), which differ in printf '%d' "'<high byte>".

load test_helper

setup() {
  setup_test_env
  BASHES="bash"
  [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo $BASH_VERSINFO')" != "$(bash -c 'echo $BASH_VERSINFO')" ] && BASHES="bash /bin/bash"
  cat > "$TEST_SKILL_DIR/ref.sh" <<'REF'
ref_encode() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { for (n = 0; n < 256; n++) ord[sprintf("%c", n)] = n }
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c ~ /[A-Za-z0-9._\-]/) printf "%s", c
        else printf "%%%02X", ord[c]
      }
    }
  '
}
ref_decode() {
  printf '%s' "$1" | LC_ALL=C awk '
    # %00 is the one deliberate difference: the builtin decode yields nothing for it.
    BEGIN { for (n = 1; n < 256; n++) byte[sprintf("%02X", n)] = sprintf("%c", n) }
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "%") {
          hex = substr($0, i + 1, 2)
          printf "%s", byte[hex]
          i += 2
        } else printf "%s", c
      }
    }
  '
}
ref_st_conf() {
  local sd="$1" type="$2" key="$3" conf line val
  conf="$sd/drivers/types/$type/type.conf"
  [ -f "$conf" ] || return 0
  line="$( { grep -E "^[[:space:]]*${key}[[:space:]]*=" "$conf" 2>/dev/null || true; } | head -1)"
  [ -n "$line" ] || return 0
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}
REF
}

teardown() { teardown_test_env; }

run_cmp() {   # <bash> <script body>; prints mismatches
  "$1" -c "source '$TEST_SKILL_DIR/ref.sh'; source '$SCRIPTS/lib/name-encode.sh'; source '$SCRIPTS/lib/session-team.sh'; SCRIPT_DIR='$SCRIPTS'; $2"
}

@test "encode matches the awk reference for ASCII, UTF-8, separators and a raw newline" {
  cat > "$TEST_SKILL_DIR/cmp.sh" <<'CMP'
source "$TEST_SKILL_DIR/ref.sh"
source "$SCRIPTS/lib/name-encode.sh"
bad=0
for s in "plain-name_1.x" "a b" "a/b" "a%b" "カーソル 三" "codex__one" "é€😀" $'a\nb' "" 'x\y' "q'q" $'t\tt' "'"; do
  [ "$(_actas_lock_encode "$s")" = "$(ref_encode "$s")" ] || { echo "encode mismatch [$s]"; bad=1; }
done
exit $bad
CMP
  local b
  for b in $BASHES; do
    run "$b" "$TEST_SKILL_DIR/cmp.sh"
    [ "$status" -eq 0 ] || { echo "$b: $output"; return 1; }
  done
}

@test "decode matches the awk reference including malformed escapes and a newline inside a percent" {
  cat > "$TEST_SKILL_DIR/cmp.sh" <<'CMP'
source "$TEST_SKILL_DIR/ref.sh"
source "$SCRIPTS/lib/name-encode.sh"
bad=0
for s in "%41" "%a" "%2f" "%GGx" "%4" "%" "%%" "%41%42" "a%20b" "%E3%82%AB" "%0A" "x%7Ey" $'%4\n1' "plain" "" "%e3%82%ab" "100%"; do
  [ "$(_actas_lock_decode "$s")" = "$(ref_decode "$s")" ] || { echo "decode mismatch [$s]"; bad=1; }
done
exit $bad
CMP
  local b
  for b in $BASHES; do
    run "$b" "$TEST_SKILL_DIR/cmp.sh"
    [ "$status" -eq 0 ] || { echo "$b: $output"; return 1; }
  done
}

@test "decode inverts encode for names with UTF-8 and spaces" {
  local b
  for b in $BASHES; do
    run run_cmp "$b" '
      s="カーソル 三/a%b__c"
      [ "$(_actas_lock_decode "$(_actas_lock_encode "$s")")" = "$s" ]'
    [ "$status" -eq 0 ] || { echo "$b: $output"; return 1; }
  done
}

@test "_agmsg_st_conf matches the grep|head reference for every key of every type manifest" {
  local b
  for b in $BASHES; do
    run run_cmp "$b" '
      bad=0
      for conf in "$SCRIPT_DIR"/drivers/types/*/type.conf; do
        t="${conf%/type.conf}"; t="${t##*/}"
        for key in session_env session_team_prefix session_seat session_marker session_sid_strict_uuid session_team nosuchkey; do
          [ "$(_agmsg_st_conf "$t" "$key")" = "$(ref_st_conf "$SCRIPT_DIR" "$t" "$key")" ] || { echo "conf mismatch $t $key"; bad=1; }
        done
      done
      exit $bad'
    [ "$status" -eq 0 ] || { echo "$b: $output"; return 1; }
  done
}

@test "_agmsg_st_conf matches the reference on spaced, commented, CRLF and unterminated manifests" {
  local t="$SCRIPTS/drivers/types/fixture"
  mkdir -p "$t"
  printf '# session_env=COMMENTED\n  session_env =  SPACED_VAL  \nsession_team_prefix=a=b\r\nsession_seat=last-no-newline' > "$t/type.conf"
  local b
  for b in $BASHES; do
    run run_cmp "$b" '
      bad=0
      for key in session_env session_team_prefix session_seat session_marker; do
        [ "$(_agmsg_st_conf fixture "$key")" = "$(ref_st_conf "$SCRIPT_DIR" fixture "$key")" ] || { echo "conf mismatch $key"; bad=1; }
      done
      [ "$(_agmsg_st_conf fixture session_env)" = SPACED_VAL ] || { echo "no trim"; bad=1; }
      exit $bad'
    [ "$status" -eq 0 ] || { echo "$b: $output"; return 1; }
  done
}

@test "_agmsg_st_conf resolves the manifest dir from the sourced file when SCRIPT_DIR is unset" {
  run env -u SCRIPT_DIR bash -c "source '$SCRIPTS/lib/session-team.sh'; _agmsg_st_conf claude-code session_team_prefix"
  [ "$status" -eq 0 ]
  [ "$output" = "s-" ]
}
