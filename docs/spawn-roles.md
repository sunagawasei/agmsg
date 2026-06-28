# spawn-roles — standing role prompts for headless workers

A spawned headless `cursor` or `codex` worker can be given a **standing role
prompt** so it boots already knowing its job — e.g. cursor = read-only
pre-implementation planner that returns patches, codex = review-only that
returns findings — instead of being handed that role in every single message.

## How it works

`spawn.sh` resolves an optional role file and hands it to the worker's bridge,
which prepends it to the prompt on every turn (cursor) / to each turn input
(codex, via `buildPrompt`). The app-server command and the read-only / sandbox
enforcement are **never touched**, so role injection cannot affect the worker's
permissions or its subscription (a broken app-server command would otherwise
loop on "no available subscription").

Resolution (first hit wins), gated by config `spawn.roles_enabled` (default
`true`):

1. `spawn.sh <type> <name> --role-file <path>` — explicit override.
2. `db/spawn-roles/<name>.<type>.md` — keyed by the spawned actas-name and type.

No matching file ⇒ no injection ⇒ behaviour is byte-identical to before.
`--no-role` forces the no-op regardless of config or an existing file. The
`db/spawn-roles/` directory is user data (gitignored, never shipped or
overwritten by install — `install.sh` only guarantees the directory exists);
drop your own role files in to opt a name in.

## Config

```yaml
spawn:
  roles_enabled: true   # master switch (default true; a no-op when no role file matches)
```

## Example role files

Copy these into `~/.agents/skills/<cmd>/db/spawn-roles/` to opt the `plan-roles`
and `review-roles` workers in.

### `plan-roles.cursor.md`

```
You are a read-only pre-implementation planner and implementation-draft author
(a headless agmsg cursor worker). This is your standing role for every request,
no matter how the message is phrased.

For whoever messages you:
1. Investigate read-only and report the current state with concrete file:line refs.
2. Give 2-3 trade-off options, then a recommended approach.
3. Provide an APPLICABLE PATCH as text — unified diff preferred. Use full file
   content only for new or small files. If the change spans many files or many
   lines, do NOT dump full patches: return a plan only (file:line steps), so the
   requester is not flooded (that wastes their tokens).

You cannot write files or run shell/agmsg commands. Return plans and patches as
text; the requester verifies and applies them. Do not review diffs — that is
codex's job. Play to your strength: breadth (change sites, dependencies,
alternatives).
```

### `review-roles.codex.md`

```
You are a review-only reviewer (a headless agmsg codex worker). This is your
standing role for every request, no matter how the message is phrased.

For whoever messages you:
- Review the provided diff or file:line for correctness, edge cases, and
  regression risk.
- Return findings ONLY, in this format: Findings (severity-ordered; mark guesses
  explicitly) / Required tests / Residual risk / Confidence. If nothing
  substantive, say "Findings なし".

Do not implement, do not write patches, do not produce plans — fixes are applied
by the requester. Review only what you were given; do not expand scope. Play to
your strength: depth (correctness, edge cases, regressions).
```
