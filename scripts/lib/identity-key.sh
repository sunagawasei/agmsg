#!/usr/bin/env bash

# Canonical opaque marker for a team/name identity in bridge argv.
#
# The ':' terminator is outside both the base64url alphabet and base64 padding.
# It makes exact identity matching independent of argv position: an encoded key
# can be a prefix of another encoded key, but a terminated key cannot.
[ -n "${_AGMSG_IDENTITY_KEY_SH:-}" ] && return 0
_AGMSG_IDENTITY_KEY_SH=1

AGMSG_IDENTITY_KEY_TERMINATOR=':'
readonly AGMSG_IDENTITY_KEY_TERMINATOR

agmsg_identity_key() {
  if [ "$#" -ne 2 ]; then
    echo "agmsg_identity_key: expected <team> <name>" >&2
    return 2
  fi

  printf '%s\t%s' "$1" "$2" \
    | base64 \
    | tr -d '\r\n' \
    | tr '+/' '-_' \
    || return
  printf '%s' "$AGMSG_IDENTITY_KEY_TERMINATOR"
}
