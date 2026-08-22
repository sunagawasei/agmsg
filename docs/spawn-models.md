# spawn-models — per-worker models for headless workers

Headless `codex` and `cursor` workers can be given a model id keyed by their
spawned actas name, so a persistent worker can use a different model without
changing the runtime's global configuration. Codex also supports per-worker
reasoning effort. Cursor can verify the effective model display label reported
by `cursor-agent` on every turn.

**Scope: headless `codex` and headless `cursor`.**

- An interactive (TUI) spawn of any type already has a working `--model` flag
  (wired via the manifest's `model_arg=`, e.g. `-m` for codex) — unaffected by
  this doc.
- With no override, a headless codex worker falls back to its global
  `~/.codex/config.toml` model — the app-server command's tail is unchanged
  (still ends at `approval_policy=never`, with no model/effort `-c` clause
  appended).

## Headless cursor

The pinned model resolution order is:

1. `spawn.sh cursor <name> --headless --model <id>`.
2. config `spawn.cursor_model.<name>`.
3. unset, preserving the Cursor global/default model behavior.

`spawn.cursor_model_label.<name>` is optional. When both a pin and label are
configured, the bridge compares each alternative byte-for-byte with the display
name in each stream-json `system/init` event. A `|` in the configured value is a
separator of exact alternatives (ASCII space/tab next to `|` is stripped from
the spec only). It does not normalize the reported label, match ids, or use
substrings. Without a label the effective display name is recorded but not
compared; without a pin, the bridge does not require the init event to have a
model field. Pin every `init.model` string observed for that id — Cursor's
catalog rename of one `--model` id can leave two live display names, and a
single-label pin dead-letters the other.

```sh
agmsg config set spawn.cursor_model.wall grok-4.6
agmsg config set spawn.cursor_model_label.wall "Cursor Grok 4.6 High Fast"
# Same model id, two observed init.model strings:
# agmsg config set spawn.cursor_model_label.wall "Catalog Name|Stale Init Name"
```

Cursor fallback resolution is:

1. bridge `--no-fallback` (explicit disable).
2. config `spawn.cursor_fallback_model.<name>` when non-empty.
3. `AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL`, preserving the distinction between
   unset and explicitly empty.
4. disabled by default when a model is pinned.
5. legacy `composer-2.5` default when unpinned.

An explicitly empty environment variable becomes the bridge flag
`--no-fallback`; no sentinel model id is used. A configured fallback is opt-in
for pinned workers because an implicit fallback would break the meaning of a
model pin. An exact model-label mismatch is terminal: the generated answer is
discarded and the input is immediately dead-lettered without a fallback turn.

Model and fallback ids must be non-empty ASCII values matching
`^[A-Za-z0-9._-]+$` and must not start with `-`. Spawn rejects malformed values
before `create-chat`. Character-valid unknown ids pass spawn because agmsg does
not call the external model catalog; Cursor reports them as a first-turn error.

`ensure-headless.sh cursor <project>` is intentionally session-team-only. It is
a no-op outside a Claude session team, so a long-lived wall/brainstorming Cursor
worker must be operated manually:

```sh
scripts/spawn.sh cursor wall --team <team> --project <repo> --headless
scripts/despawn.sh <team> <leader-name> wall --force
```

## Headless codex

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
