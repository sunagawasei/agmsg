# 0005. Session-team message retention

Status: Accepted

## Context

`teams/s-<uuid>/` is removed by the TTL GC (`delivery.session_team_ttl_days`), but the team's rows in the sqlite event log (`events`, the legacy `messages` mirror, `read_cursors`) stayed forever, as did `run/cursor-bridge.<team>.*`. Resuming a session used to return to its whole history.

## Decision

- A team's rows are deleted when they are older than `delivery.message_retention_days` (default 7) and the team is proven to be a session team. Resume now returns only the history inside that window.
- Proof is `teams/<team>/session-team`, written by session-start only when its join created the dir, or `run/session-tombstone.<team>`, written when the TTL GC removed a marked dir. The name `s-<uuid>` alone is never proof. A pre-existing dir of that name (a project team) is never marked.
- Deletion re-reads the tombstone under the team lock and stops when it is gone. A dry-run of `gc-session-orphans.sh` uses a read-only veto (any inflight record vetoes) and never reaps inflight records.
- Deletion runs under the team's lifecycle lock, after the same vetoes as the dir GC (bare owner alive, live bridge, unverified placement, live inflight) and a check that the dir is still absent. It is one sqlite transaction over `events`, `messages` and `read_cursors`, selected by team and age.
- Rows younger than the window survive the dir GC; later SessionStarts sweep tombstoned teams. A tombstone is removed only when the team has no rows and the tombstone is itself older than the window.
- Teams that predate the marker are handled only by `scripts/gc-session-orphans.sh --apply` (default `--dry-run`).
- The TTL GC also removes `run/cursor-bridge.<team>.*`.
- Only the sqlite storage driver is supported; with another active driver the sweep does nothing.
- No VACUUM: deleted rows become free pages that later inserts reuse.

## Consequences

- The vetoes exist in the TTL block of `session-start.sh` and in `lib/session-retention.sh`; `tests/test_session_retention.bats` pins that both agree.
- `gc-session-orphans.sh --apply` also deletes a project team named `s-<uuid>` whose dir is gone, with no way back.
- A `send.sh --force` to a tombstoned team after its tombstone is removed leaves rows no automatic pass collects.
- Retention compares wall-clock timestamps; a clock rollback or imported past timestamps are treated as old.
- A Cursor-only machine gets marker/tombstone through the same SessionStart path, but the GC pass itself still runs at the next SessionStart on that machine.
- `join.sh` writes the marker itself, under the team lock, in the same step that creates `config.json` (`AGMSG_JOIN_MARK_SESSION_TEAM=1`, set only by session-start). A later joiner of an existing team never marks it.
- The TTL GC removes the team dir and bridge artifacts outside the team's lifecycle lock (unchanged). Only the row delete is serialized with SessionStart, so a resume racing the dir removal can still lose its dir; the rows are protected by the re-check under the lock.
- With a non-sqlite storage driver retention is off and only the sweep's skip is visible.
- A tombstone is dropped when an unmarked dir of the same name is seen or reaped, so a later project team of that name is not taken for the old session team. A project team created and removed between two SessionStarts leaves the old tombstone valid.
- `gc-session-orphans.sh --apply` deletes a team only when no row is inside the window at delete time; a row that arrives after the dry-run check makes it skip the team.
