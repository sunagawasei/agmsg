# agmsg for OpenCode

OpenCode is supported for **manual and turn/off delivery workflows**.

`monitor` mode routes incoming messages through the external [`opencode-sentinel`](https://github.com/tsukimiya/opencode-sentinel) plugin (a Monitor-tool equivalent for OpenCode); when the plugin is not installed the rule instructs a fallback to turn mode, which the agent follows rather than agmsg enforcing it. `spawn opencode` is supported via `opencode --prompt` (TUI mode). `both` is not supported. OpenCode + Ollama is a useful local coding agent that can participate in an agmsg team alongside Claude Code, Codex, Gemini CLI, and other CLI agents.

## Install

**Alongside Codex (typical setup):**

```bash
bash <(curl -fsSL https://agmsg.cc/install.sh)
```

When `~/.config/opencode/` already exists, the installer automatically places
an OpenCode-typed `SKILL.md` at `~/.config/opencode/skills/agmsg/SKILL.md`
without touching the shared `~/.agents/skills/agmsg/SKILL.md` (which stays
Codex-typed). This is the recommended approach for mixed Codex + OpenCode teams.

**OpenCode-only (no Codex):**

```bash
bash <(curl -fsSL https://agmsg.cc/install.sh) --agent-type opencode
```

`--agent-type opencode` overwrites the shared `~/.agents/skills/agmsg/SKILL.md`
with the OpenCode template. Use this only when Codex is **not** installed; it
will break Codex identification if both agents share the same `~/.agents/` path.

From a local clone, substitute `bash <(curl ...)` with `./install.sh`.

The installer places an OpenCode-typed `SKILL.md` at
`~/.config/opencode/skills/agmsg/SKILL.md`. This is the global skill path
OpenCode reads and takes priority over the shared
`~/.agents/skills/agmsg/SKILL.md` (which is Codex-typed). Without this,
OpenCode would pick up the Codex template and identify itself as `codex`.

OpenCode skill search order (first match wins):
1. `.opencode/skills/<name>/SKILL.md` — project-local
2. `~/.config/opencode/skills/<name>/SKILL.md` — global config ← installed here
3. `~/.claude/skills/<name>/SKILL.md` — Claude-compatible fallback
4. `~/.agents/skills/<name>/SKILL.md` — agent-compatible fallback (Codex-typed)

## Join a team

From OpenCode, run:

```
$agmsg
```

On first run it prompts for a team name and agent name, then joins you to the team. Choose delivery mode `turn` or `off` when prompted.

Or join directly from the shell:

```bash
~/.agents/skills/agmsg/scripts/join.sh <team> <agent_name> opencode "$(pwd)"
~/.agents/skills/agmsg/scripts/delivery.sh set turn opencode "$(pwd)"
```

## Common actions

Check inbox:

```
$agmsg
```

Send a message:

```
$agmsg send claude check this draft
```

Show team members:

```
$agmsg team
```

Show message history:

```
$agmsg history
```

## Delivery modes

| Mode      | Supported | Notes |
|-----------|:---------:|-------|
| `monitor` | ✓         | Real-time push via the [`opencode-sentinel`](https://github.com/tsukimiya/opencode-sentinel) plugin's `sentinel_monitor` tool — same shape as Claude Code's Monitor. The rule instructs a fallback to turn-mode self-checks when the tool is unavailable |
| `turn`    | ✓         | Instruction rule runs check-inbox after each tool call |
| `off`     | ✓         | Manual `$agmsg` only |
| `monitor` | ✗         | Requires Monitor tool — not available in OpenCode |
| `both`    | ✗         | Requires monitor |

Switch mode:

```
$agmsg mode turn
$agmsg mode off
```

Requesting `monitor` or `both` returns an error:

```
Error: 'monitor' mode is not supported for opencode (no Monitor-tool equivalent). Use 'turn' or 'off'.
```

Then set the mode and follow the rule's instruction to launch a resident
watcher via `sentinel_monitor`:

```
$agmsg mode monitor
```

If `sentinel_monitor` is unavailable (plugin not installed, or the OpenCode
build does not expose the tool), the rule tells the agent to fall back to
turn-mode self-checks instead, so `monitor` degrades to `turn` rather than
failing outright.

Worth knowing what that guarantees and what it does not. agmsg writes the rule;
it does not detect whether the tool exists, so the fallback is an instruction
the agent follows rather than a code path agmsg enforces. An agent that ignores
it delivers nothing in `monitor` mode, and nothing reports that. If you need
delivery that does not depend on the agent honouring the rule, set `turn`.

## Spawn

`spawn opencode` is not supported. Spawn is limited to `claude-code` and `codex`.

## Typical team setup

```text
tmux
├─ Claude Code        Main implementation — monitor mode
├─ Codex              Review / design checks — turn mode
├─ OpenCode + Ollama  Local tasks (research, drafts, tests) — turn mode
└─ agmsg SQLite       Shared message store
```

OpenCode + Ollama is well-suited for local, low-cost tasks such as:
- Research and investigation
- README updates
- Drafting small test cases
- Mechanical edits

## Known limitations

- `monitor` mode depends on the external `opencode-sentinel` plugin — without it the rule instructs a fallback to `turn`, which is followed by the agent rather than enforced by agmsg
- No native OpenCode plugin integration

These may be addressed in future releases.
