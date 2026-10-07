# 0007. Session-team immediate reap

Status: Accepted

## Context

A session team (`teams/s-<uuid>/`) belongs to one host session. The session id is the same across `--continue`/`--resume`, so SessionStart fires again with the same id after a resume. Keeping the old team for such a resume (0005) meant the dir, run state and rows outlived their owner for days, and a resumed session saw a mix of old and new traffic.

## Decision

- A session team is not reused by a resume. When its owner dies, the team is removed at once: `teams/<team>/`, its run state, and every row of the team. A resume re-fires SessionStart with the same id, removes the previous generation's team, and joins a new, empty team of the same name. Unread messages and history of the previous generation are not carried over.
- The owner is the live instance that answers to the bare session id (`agmsg_instance_alive "${team#s-}"`). Deletion is done by `agmsg_session_team_reap_dead` (`scripts/lib/session-retention.sh`), called from:
  - `session-start.sh`, for the previous generation: inside the team's lifecycle lock, before cc-instance is published;
  - `session-start.sh`, for the TTL block: every `teams/s-*` goes through the same function;
  - `session-end-worker.sh`: when the session has no drain targets (`SNAPSHOT_COUNT=0`) and at the end of a normal teardown.
- A team is deleted only when it carries the marker `teams/<team>/session-team` and, under the lifecycle lock, none of these vetoes holds: owner alive, live bridge, unverified placement, live inflight. mtime and `delivery.session_team_ttl_days` are not read. After the lock is taken, dir existence, the marker and the session class are checked again, because `join.sh` takes no lifecycle lock and a project team of the same name may have replaced the dir.
- Order inside the lock, after all vetoes pass:
  1. All rows of the team in `events`, `messages` and `read_cursors` are deleted in one sqlite transaction, with no date condition. `delivery.message_retention_days` is not consulted. No tombstone is left. When this fails nothing has changed (dir, marker and run state stay) and the result is `skipped:db-failed`; the next reap retries.
  2. `teams/<team>` is renamed to `run/reaping.<team>.<pid>.<random>`. This ends the generation. When the rename fails the result is `skipped:rename-failed`; dir and marker stay, only the rows are gone, and the next reap retries.
  3. The run state is removed: `run/codex-<team>-cwd`, `run/claude-code-<team>-*-cwd`, `codex-`/`claude-code-`/`cursor-bridge.<team>.*`, `spawn.<team>__*`, `pending-teardown.<team>__*`, `placement.<team>__*.lock`, and `run/inflight-outbox.<encoded team>=*` (sends to a team without a dir are refused, so a leftover outbox record would be retried forever).
  4. The renamed dir is removed with `rm -rf`. When this fails only garbage remains.
- `agmsg_retention_sweep` handles every `run/reaping.<team>.<pid>.<random>` at the next SessionStart:
  - A live or unreadable `<pid>` leaves it alone.
  - A dead `<pid>` makes the sweep take the team's lifecycle lock. Only when the renamed dir still holds the marker, `teams/<team>` is absent and no live veto holds does it finish the reap (all rows, run state, `rm -rf`).
  - When one of these conditions is missing, it only removes the renamed dir. This includes an owner that is alive, i.e. a new generation already running.
- `send.sh` refuses `--force` to a name that `agmsg_session_team_class` calls a session team when `teams/<team>` does not exist and `delivery.session_team` is enabled. For claude-code that is `s-` plus 1-128 characters of `[0-9A-Za-z_-]`, no marker needed. A project team named `s-foo` without a dir is therefore refused too: the `s-` prefix is reserved for session teams. Project teams with other names still accept pre-registration sends. A `--force` to an existing session team (inflight outbox compensation, bridge failure compensation, drain-timeout notice, Cursor inject-watch) goes through. With `delivery.session_team` off the guard does nothing.
- When step 3 fails, `agmsg_session_team_reap_dead` returns `reaped-with-leftovers` and logs the reason.
- The previous-generation step of SessionStart (inside the lock, before cc-instance is published) covers the case where the dir is already gone: it deletes every row of its own `s-<sid>` through `agmsg_session_team_purge_orphan_rows`. The purge runs only for the session's own bare sid, with no `teams/<team>`, inside the lock, past the `cc_instance_current` guard and the live vetoes. It counts and deletes only the tables that exist among `events`, `messages` and `read_cursors`, so an older database without `read_cursors` is purged too. Marker and tombstone are not used as proof: the name is the session's own id, and a project team of that name has a dir and is excluded. It is skipped for the same pid and sid again (`/compact`), and a live same-sid instance of another pid (a parallel resume) vetoes it. This collects rows written after the row delete by a send that had already passed its roster and dir check.
- `message_retention_days` remains in use only by the tombstone sweep (teams reaped by an older version) and by `gc-session-orphans.sh`.
- `join.sh` writes the marker before `config.json` when `AGMSG_JOIN_MARK_SESSION_TEAM=1` (set by session-start). When the marker cannot be written, the join fails.
- The rename needs `teams/` and `run/` on one filesystem. Across filesystems `mv` is copy and delete, which is not atomic. The code does not test for this; it only treats a failed `mv` as `skipped:rename-failed`.

Relation to 0005:

- Decision 1 (history inside the window comes back on resume) and decision 5 (rows outlive the dir) are Superseded: a resume starts empty, and rows and dir go together.
- Decisions 2-4 stay valid: the marker/tombstone proof, re-reading the tombstone under the lock, and deletion under the lifecycle lock with the four vetoes and one transaction.

## Consequences

Cases where the team is not removed at owner death:

- (a) After a crash, nothing runs the reap. The team stays until the next SessionStart on that machine, whose TTL block reaps every dead `s-*`.
- (b) A bridge-attached session that was closed is draining for up to 600 s (`drain.deadline_s`). A resume in that window finds the team vetoed by `live-bridge`, so it keeps the old team and re-joins it, with its history.
- (b2) When the row delete fails, the dir is not moved and the reap is `skipped:db-failed`. SessionStart ignores a skipped reap and goes on to join, so the resume continues in the old team with its history, like (b). This is the fail-closed side.
- (c) A bare SessionStart (no `CC_PID`) cannot publish cc-instance, so it skips the previous-generation reap and its own team in the TTL block. A resume through it reuses the old team. Because no cc-instance exists, the TTL loop of another session's SessionStart can judge that session's team (no live bridge) to have a dead owner and reap it while the session is alive. A session's own SessionStart never reaps its own team. Environments where the pid cannot be resolved are rare; this deletion is accepted.
- (d) A team from before the marker has no proof and is never removed automatically. Only `gc-session-orphans.sh --apply` (default `--dry-run`) handles it.
- (e) A placement of `%`, `@` or `herdr:` does not veto, so an interactive worker in such a pane loses its registration when its owner dies. A plain `send` then fails with `team '<team>' has no registered agents`, and `send --force` is refused because the session team has no dir. A send that passed the roster and dir check may stall for any time before it writes, so rows can appear in a team without a dir at any time from the row delete on, with no upper bound. Rows written after the dir was renamed away are purged by the next SessionStart of the same session id. Rows of a session id that is never resumed are collected only by `gc-session-orphans.sh --apply`.
- (f) When the marker write fails, `join.sh` has already created `teams/<team>/` and exits before `config.json`. The empty dir stays; it has no marker, so it is not reaped.
- (g) Unread messages of a dead owner's team cannot be restored. There is no tombstone and no retention window.
- (h) `reaped-with-leftovers` (run state that could not be removed) is not retried and not collected automatically.

Accepted residues:

- (j) After the new generation has joined, an old pane sender that sends to the team name (`--force` or plain) lands in the new generation's history. Rows carry only the team name and no generation, so such a send cannot be told from a legitimate one of the new generation.
- (k) The purge proves a team by: the session's own bare sid in the name `s-<...>`, no dir, inside the lock, past the `cc_instance_current` guard, no live veto. Marker and tombstone are not used. A project team named `s-<uuid>` with that session's uuid, whose dir was removed with `leave.sh`, loses its remaining rows when that uuid is resumed. Using a session's uuid as a project team name is not supported.
- (l) After an owner crash, an owner-linked auto spawner can still spawn before it notices the death. There are two paths:
  - `watch.sh` runs `watchdog.sh` (`watch.sh:616`, `:626`, `:646`; the respawn is `watchdog.sh:721-722`). `watch.sh` stops when `agmsg_instance_alive` fails (`watch.sh:1332`), so the window is the delay from the crash to that check.
  - `codex-bridge-launcher.sh` loops while the owner TUI pid is alive (`:305-306`, `:372`), with the same detection delay.
  In that window the TTL loop of another session's SessionStart can pass the vetoes while a dead worker is respawned, and the reap's rename and run cleanup race the spawn. `spawn.sh` and `codex/_spawn.sh` take no lifecycle lock for the join, bridge start and spawn record (`codex/_spawn.sh` takes it only to publish the pending record, `:391-392`; `spawn.sh:502` runs `join.sh`, which creates the dir with `mkdir -p`, `join.sh:67`, without the lock). The result can be an orphan bridge and a marker-less `s-*` dir recreated by a join after the rename; that dir falls under (d) and is not collected automatically. The window is the few seconds after a crash. A normal exit closes it: `session-end.sh:136` writes the watchdog tombstone and the worker kills the watcher (`session-end-worker.sh:557-563`).

Other effects:

- A clock or `message_retention_days` change no longer affects session teams that have a marker; only the sweep and the manual gc still depend on it.
- The removal of a marked team's dir, run state and rows happens under the lifecycle lock; only the final `rm -rf` of the already renamed dir follows it, which a resume cannot observe.
- With a non-sqlite storage driver the rows are not touched; dir and run state are still removed.
- The `cur-<uuid>` teams of Cursor are not removed by this path (it accepts `s-*` only).
