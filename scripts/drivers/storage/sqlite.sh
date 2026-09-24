#!/usr/bin/env bash
# sqlite storage driver (built-in, default).
#
# Implements the storage contract (docs/spec/driver-interface.md §2, ADR 0003)
# over SQLite. Sourced by the storage facade (lib/storage.sh, agmsg_storage_load),
# so agmsg_db_path / agmsg_sqlite / agmsg_sql_readfile_path from storage.sh are in
# scope. State is an append-only `events` log (canonical JSONL: message_sent /
# message_read). The legacy `messages` table is read **read-only** and UNIONed
# into list_unread / history so an existing store keeps its inbox and history
# after #206 switches call sites onto the contract (§2.4); legacy rows are never
# migrated or mutated here.
#
# Framing (§1.4 / ADR 0003): record-returning ops write data only to stdout and
# fail with a non-zero exit; control ops (check/init/mark_read_batch/compact)
# print a §1.4 status name on stdout. The delivery cursor (§2.2) is the events.seq
# autoincrement, returned as an opaque decimal string. Read-marking is
# recipient-scoped ((team, agent)) and idempotent.

# --- helpers ---------------------------------------------------------------

_sqlite_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_sqlite_db() { agmsg_db_path; }
_sqlite_lit() { printf '%s' "$1" | sed "s/'/''/g"; }

# Run a record-returning query: strip CR but PRESERVE the sqlite exit status
# (pipefail), so a backend failure surfaces as a non-zero return instead of
# being swallowed by tr's exit 0. The backend's error text goes to stderr (a
# separate fd — it never pollutes the JSONL on stdout) so failures are
# debuggable, per §2.1 framing (#203 (1) / co1 review).
_sqlite_data() {
  ( set -o pipefail; agmsg_sqlite "$(_sqlite_db)" "$1" | tr -d '\r' )
}

# UUIDv7: 48-bit ms timestamp + version/variant + random. python3 preferred;
# fall back to a /dev/urandom shell build. No counter file (§2.5).
_sqlite_uuid7() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import os, time
ms = int(time.time() * 1000) & ((1 << 48) - 1)
b = bytearray(os.urandom(16))
b[0] = (ms >> 40) & 0xFF; b[1] = (ms >> 32) & 0xFF
b[2] = (ms >> 24) & 0xFF; b[3] = (ms >> 16) & 0xFF
b[4] = (ms >> 8) & 0xFF;  b[5] = ms & 0xFF
b[6] = 0x70 | (b[6] & 0x0F)            # version 7
b[8] = 0x80 | (b[8] & 0x3F)            # variant 10
h = b.hex()
print(f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}")
PY
    return
  fi
  local ms hex rnd
  ms=$(( $(date -u +%s) * 1000 ))
  hex=$(printf '%012x' "$ms")
  rnd=$(head -c 10 /dev/urandom | od -An -tx1 | tr -d ' \n')
  printf '%s-%s-7%s-8%s-%s\n' \
    "${hex:0:8}" "${hex:8:4}" "${rnd:0:3}" "${rnd:3:3}" "${rnd:6:12}"
}

# IN (...) list of "team:agent" pairs.
_sqlite_pair_in() {
  local out="" p t a
  for p in "$@"; do
    t="${p%%:*}"; a="${p#*:}"
    out="${out:+$out,}'$(_sqlite_lit "$t:$a")'"
  done
  printf '%s' "${out:-''}"
}

# --- contract: lifecycle (control ops, §1.4 status on stdout) ---------------

storage_check() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo missing_deps
    return 10
  fi
  echo ok
}

storage_describe() {
  printf 'name=sqlite\n'
  printf 'backend=SQLite (WAL) event log + legacy messages table\n'
  printf 'db=%s\n' "$(_sqlite_db)"
}

# Predicate for check-inbox / watch-once: skip polling until the store file
# exists. Prints nothing — callers use the exit status as a boolean, and
# check-inbox's stdout is hook JSON. The optional team argument is ignored;
# this driver is one shared file, not a per-team store.
storage_store_exists() {
  [ -f "$(_sqlite_db)" ]
}

storage_init() {
  local db; db="$(_sqlite_db)"
  mkdir -p "$(dirname "$db")" 2>/dev/null || true
  if [ -f "$db" ]; then
    agmsg_sqlite "$db" "ALTER TABLE events ADD COLUMN legacy_id INTEGER;" \
      >/dev/null 2>&1 || true
  fi
  agmsg_sqlite "$db" "
    PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS events (
      seq        INTEGER PRIMARY KEY AUTOINCREMENT,
      type       TEXT NOT NULL,
      id         TEXT NOT NULL,
      team       TEXT,
      from_agent TEXT,
      to_agent   TEXT,
      body       TEXT,
      msg_id     TEXT,
      agent      TEXT,
      at         TEXT NOT NULL,
      legacy_id  INTEGER
    );
    CREATE INDEX IF NOT EXISTS events_sent ON events(type, team, to_agent, seq);
    CREATE INDEX IF NOT EXISTS events_read ON events(type, team, agent, msg_id);
    CREATE TABLE IF NOT EXISTS read_cursors (
      team TEXT NOT NULL,
      agent TEXT NOT NULL,
      local_position INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(team,agent)
    );
    -- Legacy store (read-only here). Created so the UNION queries always parse
    -- even on a brand-new install with no pre-event-log data.
    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      team TEXT NOT NULL,
      from_agent TEXT NOT NULL,
      to_agent TEXT NOT NULL,
      body TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      read_at TEXT
    );
  " >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
}

# --- contract: messages ----------------------------------------------------

_sqlite_message_sent_sql() {
  local team="$1" from="$2" to="$3" body="$4" id="$5" at="$6"
  local tl fl ol bl il al
  tl="$(_sqlite_lit "$team")"; fl="$(_sqlite_lit "$from")"; ol="$(_sqlite_lit "$to")"
  bl="$(_sqlite_lit "$body")"; il="$(_sqlite_lit "$id")"; al="$(_sqlite_lit "$at")"
  printf '%s\n' "
    BEGIN IMMEDIATE;
    INSERT INTO messages (team,from_agent,to_agent,body,created_at)
    VALUES ('$tl','$fl','$ol','$bl','$al');
    INSERT INTO events (type,id,team,from_agent,to_agent,body,at,legacy_id)
    VALUES ('message_sent','$il','$tl','$fl','$ol','$bl','$al',last_insert_rowid());
    COMMIT;
  "
}

storage_send() {
  local team="$1" from="$2" to="$3" body="$4"
  local id at db; id="$(_sqlite_uuid7)"; at="$(_sqlite_now)"; db="$(_sqlite_db)"
  local insert; insert="$(_sqlite_message_sent_sql "$team" "$from" "$to" "$body" "$id" "$at")"
  # Try the INSERT first and only fall back to storage_init on failure (the #114
  # pattern). Running storage_init — which issues PRAGMA journal_mode=WAL and the
  # CREATE TABLE/INDEX statements — on EVERY send serializes badly under a
  # concurrent first-write fan-out and lost rows past the busy_timeout. The common
  # path is now a single INSERT; only a missing table pays the init + retry.
  if ! printf '%s\n' "$insert" | agmsg_sqlite -bail "$db" >/dev/null 2>&1; then
    storage_init >/dev/null
    printf '%s\n' "$insert" | agmsg_sqlite -bail "$db" >/dev/null 2>&1 || return 1
  fi
  printf '%s\n' "$id"
}

# storage_list_unread <team> <agent> [--limit N]
# events-unread ∪ legacy-unread (read_at IS NULL, not superseded by a read event).
storage_read_cursor_get() {
  local team="$1" agent="$2"
  storage_init >/dev/null || return 13
  _sqlite_data "SELECT COALESCE((SELECT local_position FROM read_cursors
    WHERE team='$(_sqlite_lit "$team")' AND agent='$(_sqlite_lit "$agent")'),0);"
}

storage_read_cursor_consume() {
  local team="$1" agent="$2" target="$3"; shift 3
  case "$target" in ''|*[!0-9]*) echo runtime_error; return 13 ;; esac
  local db tl al at id sql=""
  db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  at="$(_sqlite_now)"
  for id in "$@"; do
    sql="$sql
      INSERT INTO events(type,id,team,agent,msg_id,at)
      SELECT 'message_read','$(_sqlite_lit "$(_sqlite_uuid7)")','$tl','$al',
             '$(_sqlite_lit "$id")','$(_sqlite_lit "$at")'
       WHERE NOT EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
         AND r.team='$tl' AND r.agent='$al' AND r.msg_id='$(_sqlite_lit "$id")');
      UPDATE messages SET read_at='$(_sqlite_lit "$at")'
       WHERE read_at IS NULL
         AND id=(SELECT e.legacy_id FROM events e
                 WHERE e.type='message_sent' AND e.team='$tl'
                   AND e.id='$(_sqlite_lit "$id")' AND e.legacy_id IS NOT NULL);"
  done
  if ! agmsg_sqlite "$db" "BEGIN IMMEDIATE;
    $sql
    INSERT OR IGNORE INTO read_cursors(team,agent,local_position)
      VALUES('$tl','$al',0);
    UPDATE read_cursors SET local_position=MAX(local_position,MIN($target,$(_sqlite_highwater)))
      WHERE team='$tl' AND agent='$al';
    COMMIT;" >/dev/null 2>&1; then
    echo runtime_error
    return 13
  fi
  echo ok
}

storage_list_unread() {
  local team="$1" agent="$2" limit=""
  shift 2
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  storage_init >/dev/null
  local tl al; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  _sqlite_data "
    SELECT j FROM (
      SELECT json_object('type','message_sent','id',e.id,'team',e.team,
               'from',e.from_agent,'to',e.to_agent,'body',e.body,'at',e.at) AS j,
             e.at AS ts, 1 AS src, e.seq AS ord
      FROM events e
      WHERE e.type='message_sent' AND e.team='$tl' AND e.to_agent='$al'
        AND e.seq>COALESCE((SELECT local_position FROM read_cursors
                            WHERE team='$tl' AND agent='$al'),0)
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                        AND r.team=e.team AND r.agent='$al' AND r.msg_id=e.id)
      UNION ALL
      SELECT json_object('type','message_sent','id',CAST(m.id AS TEXT),'team',m.team,
               'from',m.from_agent,'to',m.to_agent,'body',m.body,'at',m.created_at) AS j,
             m.created_at AS ts, 0 AS src, m.id AS ord
      FROM messages m
      WHERE m.team='$tl' AND m.to_agent='$al' AND m.read_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                        AND r.team=m.team AND r.agent='$al' AND r.msg_id=CAST(m.id AS TEXT))
        AND NOT EXISTS (SELECT 1 FROM events e2 WHERE e2.legacy_id=m.id)
    )
    ORDER BY ts, src, ord ${limit:+LIMIT $limit};
  "
}

# Bridge/cursor machine path: id<US>from<US>body<US>at rows without stuffing the
# full unread set into sqlite3 argv (json_each on :memory: hits ARG_MAX for ~MiB
# bodies — cf. test_claude_code_bridge poison batch).
storage_list_unread_machine() {
  local team="$1" agent="$2" limit=""
  shift 2
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  storage_init >/dev/null
  local tl al; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  _sqlite_data "
    SELECT id || char(31) || from_agent || char(31) ||
           replace(replace(body, char(10), char(92)||char(110)), char(9), char(92)||char(116)) || char(31) || at
    FROM (
      SELECT e.id AS id, e.from_agent AS from_agent, e.body AS body, e.at AS at,
             e.at AS ts, 1 AS src, e.seq AS ord
      FROM events e
      WHERE e.type='message_sent' AND e.team='$tl' AND e.to_agent='$al'
        AND e.seq>COALESCE((SELECT local_position FROM read_cursors
                            WHERE team='$tl' AND agent='$al'),0)
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                        AND r.team=e.team AND r.agent='$al' AND r.msg_id=e.id)
      UNION ALL
      SELECT CAST(m.id AS TEXT), m.from_agent, m.body, m.created_at,
             m.created_at AS ts, 0 AS src, m.id AS ord
      FROM messages m
      WHERE m.team='$tl' AND m.to_agent='$al' AND m.read_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                        AND r.team=m.team AND r.agent='$al' AND r.msg_id=CAST(m.id AS TEXT))
        AND NOT EXISTS (SELECT 1 FROM events e2 WHERE e2.legacy_id=m.id)
    )
    ORDER BY ts, src, ord ${limit:+LIMIT $limit};
  "
}

# storage_mark_read_batch <team> <agent> <id> [<id> ...]  (control op)
storage_mark_read_batch() {
  local team="$1" agent="$2"; shift 2
  [ $# -gt 0 ] || { echo ok; return 0; }
  local db at tl al; db="$(_sqlite_db)"; at="$(_sqlite_now)"
  tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  storage_init >/dev/null
  local id sql=""
  for id in "$@"; do
    local idl rid resolved
    idl="$(_sqlite_lit "$id")"; rid="$(_sqlite_uuid7)"
    resolved="COALESCE((SELECT e.id FROM events e
      WHERE e.type='message_sent' AND e.team='$tl'
        AND CAST(e.legacy_id AS TEXT)='$idl'),'$idl')"
    sql="$sql
    INSERT INTO events (type,id,team,agent,msg_id,at)
    SELECT 'message_read','$(_sqlite_lit "$rid")','$tl','$al',$resolved,'$(_sqlite_lit "$at")'
    WHERE NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                      AND r.team='$tl' AND r.agent='$al' AND r.msg_id=$resolved);
    UPDATE messages SET read_at='$(_sqlite_lit "$at")'
     WHERE read_at IS NULL
       AND id=(SELECT e.legacy_id FROM events e
               WHERE e.type='message_sent' AND e.team='$tl'
                 AND e.id='$idl' AND e.legacy_id IS NOT NULL);"
  done
  agmsg_sqlite "$db" "$sql" >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
}

# --- contract: delivery cursor ---------------------------------------------

# The delivery tip is the monotonic AUTOINCREMENT high-water (largest rowid ever
# assigned to `events`), read from sqlite_sequence — NOT MAX(seq) over live rows.
# A DELETE-based storage_compact can lower MAX(seq) (e.g. by coalescing the
# tail message_read) but never the high-water, so a cursor issued before a
# compaction stays valid and a fresh tip never moves backwards (§2.7 cursor-safe).
_sqlite_highwater() {
  printf "COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'),0)"
}

storage_watch_tip() {
  storage_init >/dev/null
  _sqlite_data "SELECT $(_sqlite_highwater);"
}

storage_watch_after() {
  local cursor="$1"; shift
  case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
  local pairs; pairs="$(_sqlite_pair_in "$@")"
  # The message scan and the trailing-cursor (high-water) read MUST observe the
  # same snapshot, or a row inserted between the two statements would advance the
  # cursor past a message the scan never returned — a silent skip. A deferred read
  # transaction pins one WAL snapshot across both SELECTs, so the emitted cursor
  # never runs ahead of what the scan saw (§2.2 "never skip").
  _sqlite_data "
    BEGIN;
    SELECT json_object('type','message_sent','id',id,'team',team,'from',from_agent,
                       'to',to_agent,'body',body,'at',at)
    FROM events
    WHERE type='message_sent' AND seq > $cursor
      AND (team || ':' || to_agent) IN ($pairs)
    ORDER BY seq ASC;
    SELECT json_object('type','cursor','cursor',
                       CAST(MAX($cursor, $(_sqlite_highwater)) AS TEXT));
    COMMIT;
  "
}

# --- contract: history -----------------------------------------------------

# storage_history <team> [agent] [--limit N]  — events ∪ legacy in time order.
# With <agent>, only rows where that agent is sender or recipient; omit it (empty)
# for the whole team (§2.1 G3 — an additive widening, existing callers unchanged).
storage_history() {
  local team="$1" agent="$2" limit=""
  shift 2
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  storage_init >/dev/null
  local tl al afilter; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  if [ -n "$agent" ]; then
    afilter="AND (to_agent='$al' OR from_agent='$al')"
  else
    afilter=""
  fi
  # --limit returns the most RECENT N (inner DESC + LIMIT), re-sorted to
  # chronological order for output — the intuitive "recent history" semantics,
  # not the oldest N.
  _sqlite_data "
    SELECT j FROM (
      SELECT j, ts, src, ord FROM (
        SELECT json_object('type','message_sent','id',id,'team',team,'from',from_agent,
                 'to',to_agent,'body',body,'at',at) AS j, at AS ts, 1 AS src, seq AS ord
        FROM events
        WHERE type='message_sent' AND team='$tl' $afilter
        UNION ALL
        SELECT json_object('type','message_sent','id',CAST(id AS TEXT),'team',team,
                 'from',from_agent,'to',to_agent,'body',body,'at',created_at) AS j,
               created_at AS ts, 0 AS src, id AS ord
        FROM messages
        WHERE team='$tl' $afilter
          AND NOT EXISTS (SELECT 1 FROM events e2 WHERE e2.legacy_id=messages.id)
      )
      ORDER BY ts DESC, src DESC, ord DESC ${limit:+LIMIT $limit}
    )
    ORDER BY ts ASC, src ASC, ord ASC;
  "
}

# --- contract: export / import / compact -----------------------------------

storage_export() {
  local file="$1"
  storage_init >/dev/null
  # Forward-compat (§2.3): only the v1 event types are projected. A WHERE filter
  # (not just a CASE) keeps unknown-type rows out entirely, so they never surface
  # as a NULL → blank line on stdout, matching list_unread/history/watch_after.
  _sqlite_data "
    SELECT CASE type
      WHEN 'message_sent' THEN json_object('type','message_sent','id',id,'team',team,
             'from',from_agent,'to',to_agent,'body',body,'at',at)
      WHEN 'message_read' THEN json_object('type','message_read','id',id,'team',team,
             'agent',agent,'msg_id',msg_id,'at',at)
    END
    FROM events
    WHERE type IN ('message_sent','message_read')
    ORDER BY seq ASC;
  " > "$file"
}

storage_import() {
  local file="$1" db; db="$(_sqlite_db)"
  [ -f "$file" ] || return 1
  storage_init >/dev/null
  local line t id team frm to body msg_id agent at
  j() { sqlite3 :memory: "SELECT COALESCE(json_extract('$(_sqlite_lit "$line")','\$.$1'),'')" 2>/dev/null | tr -d '\r'; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    t=$(j type); id=$(j id); team=$(j team); at=$(j at)
    if [ "$t" = message_sent ]; then
      frm=$(j from); to=$(j to); body=$(j body)
      printf '%s\n' "$(_sqlite_message_sent_sql "$team" "$frm" "$to" "$body" "$id" "$at")" \
        | agmsg_sqlite -bail "$db" >/dev/null 2>&1
    elif [ "$t" = message_read ]; then
      agent=$(j agent); msg_id=$(j msg_id)
      agmsg_sqlite "$db" "INSERT INTO events (type,id,team,agent,msg_id,at)
        VALUES ('message_read','$(_sqlite_lit "$id")','$(_sqlite_lit "$team")',
                '$(_sqlite_lit "$agent")','$(_sqlite_lit "$msg_id")','$(_sqlite_lit "$at")');
        UPDATE messages SET read_at='$(_sqlite_lit "$at")'
         WHERE read_at IS NULL
           AND id=(SELECT e.legacy_id FROM events e
                   WHERE e.type='message_sent' AND e.team='$(_sqlite_lit "$team")'
                     AND e.id='$(_sqlite_lit "$msg_id")' AND e.legacy_id IS NOT NULL);" \
        >/dev/null 2>&1
    fi
  done < "$file"
}

# Internal (§2.7): coalesce duplicate message_read markers, keeping the earliest. (control op)
storage_compact() {
  local db; db="$(_sqlite_db)"
  agmsg_sqlite "$db" "
    DELETE FROM events WHERE type='message_read' AND seq NOT IN (
      SELECT MIN(seq) FROM events WHERE type='message_read'
      GROUP BY team, agent, msg_id);
  " >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
}
