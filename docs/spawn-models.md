# spawn-models — per-worker model / reasoning-effort for headless codex

A headless `codex` worker (see `docs/codex-monitor-beta.md` / `--headless`) can be
given its own model id and reasoning effort, keyed by its spawned actas name, so
e.g. a `codex-research` worker can run a different model than the default
`codex` reviewer without touching global config.

**Scope: headless `codex` only.**

- An interactive (TUI) spawn of any type already has a working `--model` flag
  (wired via the manifest's `model_arg=`, e.g. `-m` for codex) — unaffected by
  this doc.
- Headless `cursor` is not covered — its model comes entirely from cursor's own
  global config (`~/.config/cursor/cli-config.json`).
- With no override, a headless codex worker falls back to its global
  `~/.codex/config.toml` model — the app-server command's tail is unchanged
  (still ends at `approval_policy=never`, with no model/effort `-c` clause
  appended).

## Resolution

**Model** (first hit wins):

1. `spawn.sh codex <name> --headless --model <id>` — the same `--model` flag an
   interactive spawn accepts, reused here for the headless path.
2. config `spawn.codex_model.<name>` — keyed by the spawned actas name.
3. unset — falls back to the worker's global `~/.codex/config.toml`.

**Reasoning effort** (headless-only knob, no CLI flag):

1. config `spawn.codex_effort.<name>`.
2. unset — falls back to global config.

```yaml
spawn:
  codex_model.codex: gpt-5.6-sol        # keyed by actas name, e.g. "codex"
  codex_effort.codex: high
  codex_model.codex-research: gpt-5.6-fast
```

Set with:

```
agmsg config set spawn.codex_model.codex gpt-5.6-sol
agmsg config set spawn.codex_effort.codex high
```

**The config keys only apply when the worker's actas name matches
`^[A-Za-z0-9._-]+$`.** That name becomes a literal segment of the config.sh
dotted key (`spawn.codex_model.<name>`), and config.sh's reader/writer splice
the field into an unescaped awk regex — a name legal for `spawn.sh`/`actas`
itself (e.g. containing `+`, spaces, or other regex metacharacters) could
silently resolve to the wrong config line. For a name outside that charset,
`spawn.codex_model.<name>`/`spawn.codex_effort.<name>` are skipped entirely
(a warning is printed, the spawn still proceeds) — use `--model` instead,
which has no such restriction and works for any name.

## How it works

Both accepted values are spliced into the headless worker's app-server command
(the same `-c key=value` overrides used for the sandbox/approval policy) as
`-c model="<id>"` / `-c model_reasoning_effort="<val>"`, applied to all three of
the consultant (scratch cwd), implementer (`--implementer`, repo writable), and
reviewer (`--reviewer`, repo read-only) sandbox profiles alike.

Fail-closed input validation: the app-server command is a single string
re-parsed by `sh -lc` inside the bridge, so a value is only spliced in if it
matches `^[A-Za-z0-9._-]+$` (checked byte-wise in the C locale, not via a
locale-sensitive shell glob) — anything else (from either `--model` or the
config key) is dropped with a warning on stderr, and the spawn proceeds without
that override rather than failing. The rejected value is sanitized (control
bytes stripped, length capped) before it is echoed into that warning, so a
crafted value can't forge an extra log line or an ANSI escape sequence.

No matching flag/key ⇒ no override ⇒ the app-server command's tail is
unchanged (still ends at `approval_policy=never`, no model/effort `-c` clause
appended — verified by tests that anchor on that ending, not a full-string
equality check).
