# ADR 0009: Deliver to cursor sessions through an agmsgd channel

**Status:** accepted
**Date:** 2026-11-03

## Context

agmsgd delivers to Claude Code (stream) and Codex (hook) sessions. A cursor-agent session is notified by a per-session `inject-watch` process that types the nudge text into its herdr pane. The daemon starts from the service manager, so it does not inherit the herdr socket of the session it must reach.

## Decision

agmsgd gets a cursor channel. A cursor registration records its herdr pane as a socket-qualified locator. The channel sends the existing nudge text to that pane and never includes a message body. When a project moves from `inject-watch` to agmsgd, the record is published only after the old `inject-watch` is confirmed stopped.

## Consequences

- Positive: the daemon can address the right herdr server because the socket travels with the record, not with the daemon's environment.
- Positive: cursor sessions see the same nudge as before, so skill text and recipient behavior stay the same.
- Positive: one daemon replaces one `inject-watch` process per cursor session.
- Negative: cursor delivery through agmsgd needs herdr; `agmsg daemon offer cursor` reports it unavailable without a herdr executable, and a cursor session outside herdr keeps turn delivery.
- Neutral: `agmsg daemon enable` records the herdr executable path in `meta.herdr_path`, and leaves it empty when herdr is not installed.

## References

- [docs/design/agmsgd-architecture.md](../design/agmsgd-architecture.md) section 3.4
