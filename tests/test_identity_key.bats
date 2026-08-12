#!/usr/bin/env bats

@test "identity-key: terminator separates prefix-related unpadded base64 keys" {
  local scripts="$BATS_TEST_DIRNAME/../scripts"
  # shellcheck disable=SC1090
  source "$scripts/lib/identity-key.sh"

  # tt<TAB>aaa is 6 bytes and tt<TAB>aaabbb is 9. With both boundaries aligned
  # to a complete base64 quantum, the shorter legacy encoding is a true prefix.
  local legacy_short legacy_long short long
  legacy_short="$(printf '%s\t%s' tt aaa | base64 | tr -d '\r\n' | tr '+/' '-_')"
  legacy_long="$(printf '%s\t%s' tt aaabbb | base64 | tr -d '\r\n' | tr '+/' '-_')"
  [[ "$legacy_short" != *"="* ]]
  [[ "$legacy_long" == "$legacy_short"* ]]

  short="$(agmsg_identity_key tt aaa)"
  long="$(agmsg_identity_key tt aaabbb)"
  [ "$AGMSG_IDENTITY_KEY_TERMINATOR" = ":" ]
  [ "$short" = "$legacy_short:" ]
  [ "$long" = "$legacy_long:" ]
  [[ "$long" != "$short"* ]]
}

@test "identity-key: every producer and matcher call site uses the shared generator" {
  local scripts="$BATS_TEST_DIRNAME/../scripts" file
  local -a files=()
  # Derived from the tree, not hardcoded: call sites move (ensure-codex.sh became
  # a wrapper over ensure-headless.sh) and new ones must not skip the generator.
  while IFS= read -r file; do
    files+=("$file")
  done < <(grep -rl 'agmsg_identity_key ' "$scripts" \
    | grep -v '/lib/identity-key\.sh$' | sort)
  [ "${#files[@]}" -ge 4 ]

  for file in "${files[@]}"; do
    grep -Eq '^[[:space:]]*(source|\.) "\$SCRIPT_DIR/lib/identity-key\.sh"' \
      "$file"
    [ "$(grep -c 'agmsg_identity_key ' "$file")" -eq 1 ]
    ! grep -q '| base64' "$file"
  done
}

@test "identity-key: recursive install copy includes the new library" {
  local root="$BATS_TEST_DIRNAME/.."
  [ -f "$root/scripts/lib/identity-key.sh" ]
  grep -F 'cp -R "$SCRIPT_DIR/scripts/." "$SKILL_DIR/scripts/"' \
    "$root/install.sh" >/dev/null
}
