# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

agmsg is a cross-agent messaging primitive — CLI AI agents (Claude Code, Codex, Gemini CLI, GitHub Copilot CLI, Antigravity, OpenCode) exchange messages through a shared local SQLite database. No daemon, no network, no broker. The only required dependencies are `bash` and `sqlite3`.

## Commands

```bash
# Run the full test suite (primary CI signal)
bats tests/

# Run a single test file
bats tests/test_messaging.bats

# Run tests matching a pattern
bats --filter "send" tests/

# Check the installed version (git-describe string)
./scripts/version.sh

# Bump and sync the version string across files
./scripts/release/sync-version.sh
```

> Tests use BATS (Bash Automated Testing System). Install with `npm install -g bats` if missing. The CI workflow also shows the exact install commands used on each runner.

## Architecture: the 3-axis driver model

agmsg has three orthogonal **axes**, each with exactly one active **driver** at a time:

| Axis | What it abstracts | Bundled drivers |
|---|---|---|
| **storage** | Where messages and team state live | `sqlite` (default), `jsonl-duckdb` |
| **agent** | Per-runtime hook formats and settings locations | `claude-code`, `codex`, `gemini`, `antigravity`, `copilot` |
| **delivery** | How a recipient is notified | `monitor`, `turn`, `both`, `off` |

The three axes are fully orthogonal — any combination is valid.

**Key directories:**
- `scripts/` — directly-invokable user-facing commands (e.g. `send.sh`, `inbox.sh`, `dispatch.sh`)
- `scripts/lib/` — shared helpers sourced by commands (`storage.sh`, `validate.sh`, etc.)
- `scripts/drivers/<axis>/` — driver implementations (bundled; currently storage axis only)
- `tests/` — BATS test suite; `tests/test_helper.bash` is shared setup/teardown
- `docs/spec/` — formal driver interface contracts (authoritative for what a driver must implement)
- `docs/adr/` — Architecture Decision Records capturing *why* key decisions were made
- `templates/` — per-agent command templates (what each agent's skill invokes)

**Runtime install location:** `~/.agents/skills/agmsg/` — scripts read their own paths relative to `$0` or `BASH_SOURCE[0]`, not the repo.

## Shell script conventions

Every script must begin with `set -euo pipefail`. Drivers expose functions prefixed by axis name to avoid namespace collisions (`storage_*`, `agent_*`, `delivery_*`). Scripts source shared helpers via `source "$SCRIPT_DIR/lib/storage.sh"` (or the equivalent lib file); they never hard-code `~/.agents/`.

## AGMSG-DIRECTIVE protocol

When a driver needs the host agent to take an action (install a dependency, invoke the Monitor tool, stop a task), it emits a single line on stdout:

```
AGMSG-DIRECTIVE: {"type":"install_deps","driver":"jsonl-duckdb","commands":["brew install duckdb"],"reason":"duckdb binary not found on PATH"}
```

This is the sole IPC channel between agmsg scripts and the host agent runtime. The host agent decides whether to run the commands. Never use exit codes alone to signal these conditions.

## Storage details

- **DB path:** `~/.agents/skills/agmsg/db/messages.db` (WAL mode, resolved via `scripts/lib/storage.sh`)
- **Event log:** state is append-only (`message_sent`, `message_read`, `team_joined`, `team_left`); read status is derived by projection, not in-place updates
- **Legacy compat:** the sqlite driver reads both the old `messages` table and the new event log; writes only go to the event log
- **IDs:** all new IDs are UUIDv7 strings; legacy integer IDs are passed through as decimal strings
- **Concurrency:** `sqlite3` is called with a `busy_timeout` so concurrent writers serialize instead of failing silently

## Driver interface contract

Before implementing or changing a driver, read `docs/spec/driver-interface.md`. Every driver must implement `<axis>_check` and `<axis>_describe`; storage drivers additionally implement `storage_init`, `storage_insert_message`, `storage_unread`, `storage_mark_read`, `storage_history`, and several others. Status codes (`ok`/`missing_deps`/`corrupt_state`/`runtime_error`) are structured — callers react to the name, not just the exit code.

## Adding a driver

Place the script at `scripts/drivers/<axis>/<name>.sh`, implement the full contract from `docs/spec/driver-interface.md`, add BATS tests under `tests/`, and file an ADR if the driver changes the interface or vocabulary.

## ADRs

Non-trivial design decisions (new axis, interface change, new dependency, changed vocabulary) get an ADR in `docs/adr/`. Copy `docs/adr/template.md`, fill it in, open a PR. ADRs are immutable history — superseded ones stay in place with a forward link.

## Versioning and release

The version lives in `VERSION`. To cut a release: bump `VERSION`, run `./scripts/release/sync-version.sh`, commit, tag `v$(cat VERSION)`, push. CI handles npm publish and the rest. See `RELEASING.md` for details.
