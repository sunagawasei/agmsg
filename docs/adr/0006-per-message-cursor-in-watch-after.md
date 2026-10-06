# 0006. Per-message cursor in storage_watch_after

Status: Accepted

## Context

`watch.sh` marks a batch read by passing the trailing cursor record to `storage_read_cursor_consume`. A `ctrl:despawn` row ends the watcher before that record, so the row stayed unread and the read frontier did not move. A later watcher for the same role re-read the despawn and tore itself down.

## Decision

Each `message_sent` record of `storage_watch_after` may carry an optional `cursor`: the driver-issued position immediately after that message. The sqlite driver emits its `seq`. `watch.sh` passes it to `storage_read_cursor_consume` when it stops at a control row, so the frontier stops at that row and later messages stay unread.

## Consequences

- Core still treats the cursor as opaque; it does not read `events.seq`.
- Existing consumers ignore the extra field. `sqlite` is the only bundled storage driver, so no other driver needs to emit it; a driver that omits it keeps today's behavior (the despawn row stays unread).
