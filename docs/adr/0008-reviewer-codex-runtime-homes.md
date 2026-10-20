# ADR 0008: Keep reviewer Codex homes outside skill discovery

**Status:** accepted
**Date:** 2026-10-20

## Context

Each headless Codex reviewer or research worker needs a separate `CODEX_HOME`
with empty execpolicy rules and no user configuration. Codex also populates
that home with plugin installations, caches, and session state. Skill loaders
recursively traverse the installed skill directory, so runtime homes stored
there can exhaust their traversal budget. Team retention removes team and run
state but does not remove these homes.

## Decision

Store reviewer homes at
`$HOME/.local/state/agmsg/reviewer-codex-home/<team>/<name>/launch.<id>`.
Keep both this root and the legacy `$SKILL_DIR/reviewer-codex-home` root denied
in reviewer sandbox profiles and exclude their descendants from additional
filesystem grants. Reject a state root that resolves inside skill discovery.
Continue creating separate homes for concurrent launches and refusing symlinked
home components.

Existing homes are not moved or deleted automatically. Before relocating them,
check worker processes and open file references, then move them outside skill
roots during an idle period. Do not leave a symlink in the skills directory:
Codex follows symlinked skill directories. Authentication symlinks can be moved
without reading or copying their targets.

## Consequences

New worker plugin installations do not increase the skill traversal workload.
Homes remain available for diagnosis until explicitly removed, so this change
does not impose an automatic disk retention policy. Multiple agmsg installations
for the same user share the denied runtime root. The existing per-launch suffix
separates their homes.

## References

- [OpenAI documentation: local skill discovery](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills)
- [Session team retention](0007-session-team-immediate-reap.md)
