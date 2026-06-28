#!/usr/bin/env bats
# Unit tests for lib/spawn-role.sh — the standing-role resolver used by spawn.sh
# to hand a headless cursor/codex worker its role file. Pure lookup: gate +
# explicit override + db/spawn-roles/<name>.<type>.md convention; no match prints
# nothing (byte-identical pre-feature behaviour).

load test_helper

setup() { setup_test_env; }

# Run the resolver with SCRIPT_DIR/SKILL_DIR pointed at the test skill dir.
resolve() {  # <name> <type> <explicit> <disable>
  run env SCRIPT_DIR="$SCRIPTS" SKILL_DIR="$TEST_SKILL_DIR" bash -c '
    source "$SCRIPT_DIR/lib/spawn-role.sh"
    agmsg_spawn_role_resolve "$1" "$2" "$3" "$4"
  ' _ "$1" "$2" "$3" "$4"
}

@test "spawn-role: db/spawn-roles/<name>.<type>.md resolves to its path" {
  mkdir -p "$TEST_SKILL_DIR/db/spawn-roles"
  printf 'ROLE TEXT\n' > "$TEST_SKILL_DIR/db/spawn-roles/plan-roles.cursor.md"
  resolve plan-roles cursor "" 0
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_SKILL_DIR/db/spawn-roles/plan-roles.cursor.md" ]
}

@test "spawn-role: no matching file => empty (back-compat)" {
  resolve nobody codex "" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spawn-role: disable (=--no-role) forces empty even with a file present" {
  mkdir -p "$TEST_SKILL_DIR/db/spawn-roles"
  printf 'ROLE\n' > "$TEST_SKILL_DIR/db/spawn-roles/x.codex.md"
  resolve x codex "" 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spawn-role: explicit role-file path wins over the convention" {
  local rf="$TEST_SKILL_DIR/custom-role.md"
  printf 'CUSTOM\n' > "$rf"
  resolve anyname codex "$rf" 0
  [ "$status" -eq 0 ]
  [ "$output" = "$rf" ]
}

@test "spawn-role: gate off (spawn.roles_enabled=false) => empty even with a file" {
  mkdir -p "$TEST_SKILL_DIR/db/spawn-roles"
  printf 'ROLE\n' > "$TEST_SKILL_DIR/db/spawn-roles/x.codex.md"
  "$SCRIPTS/config.sh" set spawn.roles_enabled false >/dev/null 2>&1 || skip "config.sh set unavailable in this env"
  resolve x codex "" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spawn-role: gate off ignores even an explicit readable --role-file" {
  local rf="$TEST_SKILL_DIR/explicit-role.md"
  printf 'ROLE\n' > "$rf"
  "$SCRIPTS/config.sh" set spawn.roles_enabled false >/dev/null 2>&1 || skip "config.sh set unavailable in this env"
  resolve anyname codex "$rf" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spawn-role: name with path traversal / slash does not resolve (defence-in-depth)" {
  mkdir -p "$TEST_SKILL_DIR/db/spawn-roles"
  resolve "../escape" codex "" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  resolve "a/b" codex "" 0
  [ -z "$output" ]
  resolve "" codex "" 0
  [ -z "$output" ]
}

@test "spawn-role: a directory at the convention path does not resolve" {
  mkdir -p "$TEST_SKILL_DIR/db/spawn-roles/d.codex.md"
  resolve d codex "" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spawn-role: an explicit directory path does not resolve" {
  local dir="$TEST_SKILL_DIR/role-dir"
  mkdir -p "$dir"
  resolve any codex "$dir" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spawn-role: unreadable convention file does not resolve (no silent role-less start)" {
  mkdir -p "$TEST_SKILL_DIR/db/spawn-roles"
  local rf="$TEST_SKILL_DIR/db/spawn-roles/u.codex.md"
  printf 'ROLE\n' > "$rf"
  chmod 000 "$rf" 2>/dev/null || skip "cannot drop read perms in this env"
  if [ -r "$rf" ]; then chmod 644 "$rf"; skip "running as root: -r test is meaningless"; fi
  resolve u codex "" 0
  local st="$status" out="$output"
  chmod 644 "$rf" 2>/dev/null || true
  [ "$st" -eq 0 ]
  [ -z "$out" ]
}
