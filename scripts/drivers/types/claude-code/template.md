---
description: Agent messaging — check inbox, send messages, view history
argument-hint: "[send|ask|team|history|spawn|despawn|mode|config|reset|…]"
---

Agent messaging command. **IMPORTANT: Always use the provided scripts. NEVER directly read or edit config files, DB, or team data. There is NO register.sh — use join.sh to join a team.**

**Shell requirement:** All agmsg scripts are Bash scripts. Always execute them via `bash`, never via PowerShell or cmd directly. If your default shell is not Bash (e.g. PowerShell on Windows), wrap every command with `bash -lc '...'`. Example: `bash -lc '~/.agents/skills/__SKILL_NAME__/scripts/send.sh myteam alice bob "hello"'`. Do NOT construct DB paths manually — the scripts handle path resolution internally. If you need to redirect storage, use `AGMSG_STORAGE_PATH` (the supported override).

If asked, in ordinary language and in either English or Japanese, to re-arm this session's own agmsg monitor (no fixed trigger word — read the request as it is phrased): invoke Monitor with the standard command and description for this seat, and say nothing else.

If asked to re-arm the team's Claude Code monitors (not just this session's own): run `~/.agents/skills/__SKILL_NAME__/scripts/rearm.sh` and report what it prints.

Claude Code commands may need permission and sandbox allowlists for `~/.agents/skills/__SKILL_NAME__/scripts/` and its writable `db/`, `teams/`, and `run/` directories.

**Permission prompts.** Every command here runs through the Bash tool, so each call is gated by the permission system until the script directory is allowlisted. Without this the user is asked to confirm essentially every `__SKILL_NAME__` call. Add to `~/.claude/settings.json` (or project-level `.claude/settings.local.json`):

```json
{
  "permissions": {
    "allow": [
      "Bash(~/.agents/skills/__SKILL_NAME__/scripts/*)",
      "Bash(/Users/<you>/.agents/skills/__SKILL_NAME__/scripts/*)",
      "Bash(bash ~/.agents/skills/__SKILL_NAME__/scripts/*)",
      "Bash(bash /Users/<you>/.agents/skills/__SKILL_NAME__/scripts/*)"
    ]
  }
}
```

Four entries because a rule matches the command string as written, and these scripts are invoked both as `~/...` and as an absolute path, with or without an explicit `bash` prefix. Replace `/Users/<you>` with the user's home directory.

**Every subcommand needs its own match.** Per [Claude Code's permission docs](https://code.claude.com/docs/en/permissions), a rule must match each subcommand independently, and the recognized separators are `&&`, `||`, `;`, `|`, `|&`, `&`, and newlines. Chaining two `__SKILL_NAME__` scripts is fine — both match the entries above. The prompt returns when a subcommand those entries do not cover rides along: `delivery.sh status … ; printenv AGMSG_SPAWNED` prompts because of the `printenv`, not because of the `;`. Splitting it into its own call does not remove that prompt — it only keeps it from gating the `__SKILL_NAME__` call. Allowlist the command as well if it needs to be prompt-free.

**Sandbox compatibility.** When Claude Code's sandbox is enabled, `watch.sh` (monitor mode) runs inside the sandbox and needs to write pidfiles and SQLite WAL files under `~/.agents/skills/__SKILL_NAME__/`. If monitor mode fails with write/permission errors there, add an allowlist entry to `~/.claude/settings.json` (or project-level `.claude/settings.local.json`):

```json
{
  "sandbox": {
    "filesystem": {
      "allowWrite": [
        "~/.agents/skills/__SKILL_NAME__/"
      ]
    }
  }
}
```

The allowlist does not enable sandboxing by itself. Use `/sandbox` in Claude Code to choose a sandbox mode, or add `"enabled": true` alongside `"filesystem"` under `"sandbox"` to configure it in settings. The allowlist has no effect until sandboxing is enabled.

The allowlist merges across scopes and takes effect immediately — no restart needed. (The `BASH_SOURCE`-empty case under the sandbox — the Bash tool runs commands via pipe/eval, so `BASH_SOURCE[0]` is empty inside sourced functions — is handled internally: `watch.sh` resolves `SKILL_DIR` from `$0` and `storage.sh` falls back to it. No user configuration needed.)

**Session-team mode (`delivery.session_team`).** When this config is enabled, your identity is your OWN per-session team `s-$CLAUDE_CODE_SESSION_ID` (agent `claude`). `whoami.sh` already returns it, so `$TEAM`/`$AGENT` resolve to the session team with no extra step, and each Claude session is fully isolated — you never see other sessions' traffic. The session's codex worker is started lazily: **before the first `send`/`ask` to codex, run** `~/.agents/skills/__SKILL_NAME__/scripts/ensure-codex.sh "$(pwd)"`. It brings up a headless codex in your session team (and is a no-op when the mode is off, so it is always safe to run first). On `--continue`/`--resume` the team name is unchanged (same session id), so the re-spawned codex can read this session's prior history with `history.sh s-$CLAUDE_CODE_SESSION_ID`.

**IMPORTANT — cross-session isolation.** `$TEAM` for `send.sh`/`ask` MUST come from `whoami.sh` output (the Identity section above). Never derive the team from pidfiles, process listings, or `ls run/codex-bridge.*` — other sessions may have live bridges whose team names look similar, and using the wrong team would leak your messages into another session. As a backstop, `send.sh` refuses a send INTO another session's private team (`s-<id>`) when it is not this session's own; project-team sends are unaffected, and a deliberate cross-session send needs `AGMSG_ALLOW_CROSS_TEAM=1`. `ensure-codex.sh` also prints `ensure-codex: … in team '<name>'` on its session-team success paths so you can confirm it targeted your session's team.

**If no arguments provided (DEFAULT action — always do this when the command is invoked without arguments):**
1. **IMMEDIATELY** run inbox check for each TEAM: `~/.agents/skills/__SKILL_NAME__/scripts/inbox.sh $TEAM $AGENT`
2. Do NOT ask the user what to do — just run the inbox check.
3. If there are messages, read and respond appropriately. To reply:
   `~/.agents/skills/__SKILL_NAME__/scripts/send.sh $TEAM $AGENT <to_agent> "<message>"`

If argument is "history":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/history.sh $TEAM $AGENT`

If argument starts with "team list" (e.g. "team list", "team list --json", "team list --scope project"):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/team-list.sh <the rest of the args after "team list", unchanged>`
2. This is a distinct command from bare "team" below — check for "team list" FIRST so "list" is never mistaken for a team name.

If argument is "team":
1. For each TEAM, run: `~/.agents/skills/__SKILL_NAME__/scripts/team.sh $TEAM`

**send vs ask — pick by whether you expect a reply.** Use `ask` for any message
where you want an answer back (questions, requests, consultations, code-review
asks). Use `send` for one-way traffic (notifications, acknowledgements,
fire-and-forget, control). The difference is busy-keep: `ask` blocks until the
reply lands so the session keeps "running"; `send` returns immediately.

If argument starts with "send" (e.g. "send misaki check the server"):
1. Parse target agent and message from the arguments
2. If `<to_agent>` is `codex`, first run `~/.agents/skills/__SKILL_NAME__/scripts/ensure-codex.sh "$(pwd)"` (lazily starts this session's codex in session-team mode; no-op otherwise).
3. Determine which team the target agent belongs to, then run:
   `~/.agents/skills/__SKILL_NAME__/scripts/send.sh $TEAM $AGENT <to_agent> "<message>"`
4. This returns immediately — use it only when you do NOT expect a reply. If you
   are awaiting an answer, use `ask` instead so the turn stays active.

If argument starts with "ask" (e.g. "ask misaki does the server look healthy?"):
This is the request/reply sibling of `send` — it sends, then BLOCKS in the
foreground until <to_agent> replies to you, holding the assistant turn (and the
terminal's "running" indicator) open the whole time. This is the busy-keep path:
prefer it whenever you expect an answer so the session does not go idle while waiting.
1. Parse target agent and message from the arguments.
2. If `<to_agent>` is `codex`, first run `~/.agents/skills/__SKILL_NAME__/scripts/ensure-codex.sh "$(pwd)"` (lazily starts this session's codex in session-team mode; no-op otherwise). Then determine which team the target agent belongs to, and run:
   `~/.agents/skills/__SKILL_NAME__/scripts/send.sh $TEAM $AGENT <to_agent> "<message>" --wait --timeout 540`
   (equivalently `dispatch.sh ... ask <to_agent> "<message>"`).
3. On success it prints `status=reply` + the reply line. Read it and continue
   **in the same turn**: to keep the exchange unbroken, fire the next `ask`
   without emitting a final response (a final text response ends the turn and the
   terminal goes idle).
4. A Bash tool call caps at 10 minutes, so keep `--timeout` under that (≈540s) and
   loop `ask` calls within the turn for longer waits. On timeout it prints
   `status=timeout` and exits 2 — re-run to keep waiting, or stop and yield.
5. `ask`/`--wait` is id-scoped (it waits for a reply newer than this send), so it
   needs no inbox draining and coexists with monitor delivery. A monitor watcher
   also delivers the same reply as a later duplicate event — the `ask` output is
   authoritative; ignore the duplicate. Do not fire parallel `ask`s on the same
   from/to pair: with no conversation id yet, concurrent asks can't be correlated
   and the first reply satisfies whichever was waiting.

If argument starts with "actas" followed by an agent name (e.g. "actas alice"):
1. Parse the new role name. If none was given (e.g. bare "actas", or the user asks you to suggest one), run `~/.agents/skills/__SKILL_NAME__/scripts/team.sh <team>` for each TEAM to see the current roster. Look for a naming convention already in play (e.g. a shared base name with role and number suffixes (`<base>-<role><n>`), or names derived from the team name) and, when one exists, propose 2-3 unused names that extend it; otherwise propose 2-3 short, distinctive identity names (not a bare tool-type label). Either way, names must not collide with the roster. Ask the user to pick one or type their own before continuing.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/identities.sh "$(pwd)" claude-code` to see whether the role is already registered for this (project, type).
3. If the name does not appear in the output, join under the existing team. Read TEAMS from the in-session whoami state (it may be a single team or comma-separated). For a single team, run `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> claude-code "$(pwd)"`. For multiple teams, ask the user which team to join the new role into, then run join.sh for that team.
4. **Pre-flight claim** the actas exclusivity lock so this role isn't already owned by another live session: `~/.agents/skills/__SKILL_NAME__/scripts/actas-claim.sh "$(pwd)" claude-code <name> "$CLAUDE_CODE_SESSION_ID"`. Read the `status=` line of the output:
    - `status=ok ...`: proceed to step 5.
    - `status=held team=<team> owner=<sid>`: another live session currently owns `<name>` in `<team>`. Tell the user: "Cannot actas as `<name>` — it is held by session `<sid>` in team `<team>`. Run `/__SKILL_NAME__ drop <name>` in that session first, then retry." Then abort — do NOT touch the running Monitor.
    - `status=not_registered`: shouldn't happen if step 3 ran; treat as an error.
5. **Switch receive too — exclusive role mode.**
   a. Run TaskList. Find any task whose description begins with "agmsg inbox stream".
   b. **If a matching task is found**: TaskStop it.
   c. **If no matching task is found** (typical when /__SKILL_NAME__ actas runs as the first command of a fresh session — SessionStart hasn't fired the Monitor directive yet, or you're invoking actas before the agent acted on it): skip TaskStop entirely. There is no Monitor to stop. Do NOT attempt TaskStop with a guessed or empty task_id — it will fail with "Invalid tool parameters" and confuse the flow.
   d. Run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status claude-code "$(pwd)"` and read its **first line**.
      - **`mode: monitor` or `mode: both`**: invoke a fresh Monitor, regardless of whether step b or c applied:
        - command: `~/.agents/skills/__SKILL_NAME__/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" claude-code <name>`
        - description: `agmsg inbox stream (acting as <name>)`
        - persistent: true
        - timeout_ms: 1800000

        Check whether the environment variable `AGMSG_CC_MONITOR_KEEP_ALIVE` is set (e.g. `printenv AGMSG_CC_MONITOR_KEEP_ALIVE`). If it IS set: this watch expires after at most 30 minutes; when the expiry notice arrives, immediately re-arm it by invoking Monitor again with this exact command and description — delivery depends on it, since nothing else keeps the stream running. Re-arm it silently: no message to the user, no "re-armed", no acknowledgement, no summary — just invoke Monitor again and continue, since announcing it every 30 minutes wastes tokens for no benefit. If it is UNSET (the default), skip this paragraph — the watch still expires after 30 minutes, but nothing here asks you to re-arm it.
      - **`mode: turn`**: leave it stopped, silently. `has_st=1` is the one case `delivery.sh` can actually confirm was a deliberate choice — someone configured turn-based delivery for this project — so `actas` starting nothing here needs no explanation.
      - **`mode: off (no agmsg delivery hooks installed for this project)`**: leave it stopped (`actas` must not start automatic delivery a project wasn't configured for), but **do not treat this as silently deliberate**. `delivery.sh` cannot tell whether someone ran `mode off` here or this project was simply never configured — both leave the exact same settings file (#687 review round 3). **Tell the user** — e.g. "agmsg delivery hooks are not installed for this project; automatic delivery remains stopped. Run `/__SKILL_NAME__ mode <choice>` if you want to configure it." Keep it matter-of-fact, not a warning. Do not report `actas` as complete without saying this.
      - **`mode: off (unrecognized: ...)`**: leave it stopped too (same rule — do not guess a mode), but this is a stronger case than the no-hooks-installed one above: `delivery.sh` could not even find or read a settings file for this project, most often because the working directory does not match how the project was actually registered. **Tell the user explicitly** — e.g. "agmsg could not find a delivery configuration for this project at `<path from the message>` — delivery is stopped, but this may mean the project isn't registered here rather than that it was deliberately turned off. Check the path, or run `/__SKILL_NAME__ mode <choice>` to configure it explicitly." Do not report `actas` as complete without saying this — a silent stop here is indistinguishable from the other off cases and is what let this go unnoticed before (#687).
   The 4th argument to `watch.sh` restricts the subscription to messages addressed to `<name>` only — other roles' inbound messages stop reaching this session until another `actas` or session end.
6. Set the session's active FROM to `<name>` — use `<name>` in every `send.sh` call for the rest of this session.
7. Tell the user: "Now acting as `<name>`. Sends use `<name>` as from; receive restricted to `<name>` only."
8. **Only if this session was NOT launched via `spawn`** — check the environment variable `AGMSG_SPAWNED` (e.g. `printenv AGMSG_SPAWNED`): `spawn` exports `AGMSG_SPAWNED=1` and already named the session `<team>-<agent>` via `-n`, so when it is set, **skip this tip entirely**. When it is UNSET (a human typed `claude` then actas'd, so the session has no convention name), additionally suggest to the user: "Tip: rename this session to `<team>-<name>` with `/rename <team>-<name>` so it's easy to find in the `/resume` picker and stays labeled after a restart." `/rename` is a user-typed slash command — you cannot invoke it yourself, so only suggest it.

If argument starts with "drop" followed by an agent name (e.g. "drop alice"):
1. Parse the role name.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" claude-code <name> "$CLAUDE_CODE_SESSION_ID"` to remove only that role's registration for this project. If the role has no other registrations left, reset.sh also drops it from the team config. The 4th argument releases any actas exclusivity locks this session held on the role so peers can pick it up immediately (see #62).
3. If the session's active FROM was `<name>`, clear that state. Then:
   a. Run TaskList. Find any task whose description begins with "agmsg inbox stream".
   b. **If a matching task is found**: TaskStop it.
   c. **If no matching task is found**: skip TaskStop. Do NOT attempt TaskStop with a guessed or empty task_id.
   d. Run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status claude-code "$(pwd)"` and read its **first line**.
      - **`mode: monitor` or `mode: both`**: invoke a fresh Monitor with the default subscription (no `actas` name filter — receives every (team, agent) pair currently registered for this project that isn't held by another session):
        - command: `~/.agents/skills/__SKILL_NAME__/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" claude-code`
        - description: `agmsg inbox stream`
        - persistent: true
        - timeout_ms: 1800000

        Check whether the environment variable `AGMSG_CC_MONITOR_KEEP_ALIVE` is set (e.g. `printenv AGMSG_CC_MONITOR_KEEP_ALIVE`). If it IS set: this watch expires after at most 30 minutes; when the expiry notice arrives, immediately re-arm it by invoking Monitor again with this exact command and description — delivery depends on it, since nothing else keeps the stream running. Re-arm it silently: no message to the user, no "re-armed", no acknowledgement, no summary — just invoke Monitor again and continue, since announcing it every 30 minutes wastes tokens for no benefit. If it is UNSET (the default), skip this paragraph — the watch still expires after 30 minutes, but nothing here asks you to re-arm it.
      - **`mode: turn`**: leave it stopped, silently — the one case `delivery.sh` can confirm was deliberate.
      - **`mode: off (no agmsg delivery hooks installed for this project)`**: leave it stopped, but say so — same reasoning as the `actas` step this mirrors: this state is indistinguishable from "never configured" (#687 review round 3), so do not report it as deliberate. Do not report the drop as complete without mentioning it.
      - **`mode: off (unrecognized: ...)`**: leave it stopped, but say so with the stronger diagnostic — same reasoning as the `actas` step this mirrors (#687). Do not report the drop as complete without mentioning it.
4. Tell the user: "Dropped role `<name>` from this project."

If argument starts with "spawn" (e.g. "spawn codex reviewer", "spawn cursor planner", "spawn claude-code alice --window"):
1. Parse `<type>` (any spawnable type — run `spawn.sh` with no args to list them; currently `claude-code`, `codex`, `cursor`, `grok-build`, `hermes`), `<name>`, and any options (`--project`, `--team`, `--window`, `--split h|v`, `--terminal`, `--no-wait`, `--ready-timeout <secs>`, and for headless-capable types (`claude-code`, `codex`, `cursor`) `--headless` / `--interactive`).
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/spawn.sh <type> <name> --project "$(pwd)" [options]`
   - spawn.sh pre-joins `<name>`, then opens a tmux pane/window (when this session is inside tmux) or a new OS terminal, and launches the target CLI with `/__SKILL_NAME__ actas <name>` as its initial prompt.
   - By default it BLOCKS until the new agent's watcher attaches and prints `status=ready` — so you can message `<name>` right away. It prints `status=timeout` and exits 3 if not ready within `--ready-timeout` (default 90s); pass `--no-wait` for fire-and-forget. Types with `monitor=no` (e.g. `codex`, `cursor`, `grok-build`) skip the wait (no awaitable readiness).
   - It refuses early if `<name>` is already held by another live session, if the target CLI is not installed, or if there is no tmux and no usable terminal (headless).
   - **claude-code headless**: `--headless` runs one-shot `claude -p` turns through a persistent no-terminal bridge. Every layout uses a neutral scratch cwd and generated fail-closed sandbox settings. The default consultant has no repo `--add-dir`; `--implementer` grants repo Edit/Write; `--reviewer` grants repo read while denying repo writes and credential-targeted reads. Set `spawn.claude_headless=true` for the default, `spawn.claude_reviewer=true` for reviewer default, or `spawn.claude_implementer.<name>=true` per worker. Model, effort, and turn timeout use `spawn.claude_model.<name>`, `spawn.claude_effort.<name>`, and `spawn.claude_turn_timeout.<name>`.
   - **claude-code reviewer add-dirs**: `spawn.claude_inherit_add_dirs=true` opts reviewers into persisted `permissions.additionalDirectories`; `spawn.claude_inherit_add_dirs.<name>` overrides it per worker. The default is off, so reviewer read scope is never widened silently.
   - **codex headless**: `--headless` runs codex as a no-terminal bridge worker (no window) that talks over the bus — useful as a persistent reviewer. Its cwd is a neutral scratch dir under `run/` and it is sandboxed to read anywhere but write only agmsg's `db/teams/run` (`--project` here selects the team/subscription, not codex's cwd). Setting config `spawn.codex_headless=true` makes every codex spawn headless by default; pass `--interactive` to force a one-off TUI.
   - **codex reviewer**: `--reviewer` (headless only; default from config `spawn.codex_reviewer`) makes codex's cwd the target repo under a read-only permission profile — it can explore the repo but only write agmsg's `db/teams/run`, and unrelated paths (e.g. `~/.ssh`) stay unreadable. Set config `spawn.codex_inherit_add_dirs=true` to additionally grant the reviewer READ access to the directories this Claude session was given via `/add-dir` (`permissions.additionalDirectories` in the project's `.claude/settings{,.local}.json`), so codex sees the same out-of-repo dirs you do. Off by default (it widens the read scope); the spawn output lists any inherited read roots. Only persisted add-dirs are picked up — directories added with `/add-dir` mid-session aren't written to settings, so re-add them there to share with codex.
   - **codex implementer**: `--implementer` (headless only; default from config `spawn.codex_implementer.<name>`) makes codex's cwd the target repo under workspace-write — the repo is WRITABLE, for implementation work delegated to codex. Mutually exclusive with `--reviewer`. Replies go through agmsg's `db/teams/run` as usual; network stays off.
   - **cursor headless**: a headless cursor is always a read-only reviewer in `--project` (no scratch/consultant mode; `--reviewer` and `--implementer` are rejected). Read-only is enforced via a scratch `.cursor/cli.json` (config `spawn.cursor_readonly`, default on). Tear down with `despawn --force`.
3. Show the script's output. Do NOT TaskStop or relaunch this session's own Monitor — spawn affects a separate, newly launched agent, not this session's subscription.

If argument starts with "despawn" (e.g. "despawn reviewer", "despawn alice --force"):
1. Parse `<name>` and any options (`--force`, `--timeout <secs>`). `despawn` is the inverse of `spawn` — it tears down a member you previously spawned.
2. Determine which team `<name>` belongs to (as with `send`), then run:
   `~/.agents/skills/__SKILL_NAME__/scripts/despawn.sh <team> $AGENT <name> [--force] [--timeout <secs>]`
   - Default (graceful): sends a `ctrl:despawn` control message to `<name>`. The member's watcher drops its own role (releasing the actas lock + registration) and closes its own tmux pane, which ends the agent CLI. Blocks until the lock releases, up to `--timeout` (default 30s), then prints `status=ok`. On timeout it prints `status=timeout` and exits 3 — the member's watcher didn't respond (dead watcher, or a codex member with no Monitor); retry with `--force`.
   - `--force`: skips the message and tears the member down from the placement recorded at spawn time — kills its tmux pane/window and drops its registration. Use when the member's watcher can't respond.
3. Show the script's output. Do NOT TaskStop or relaunch this session's own Monitor — despawn affects the spawned member, not this session's subscription.

<!-- agmsg:slot mode -->
If argument is "mode", run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status __AGENT_TYPE__ "$(pwd)"`. Show the output to the user, and if it says `mode: monitor` (or `both`), say explicitly that this reports project *configuration* only — it does not prove the runtime Monitor task is attached in the current session. To confirm the runtime state, run TaskList and look for a task whose description begins with `agmsg inbox stream` (after an `actas` it reads `agmsg inbox stream (acting as <name>)`) — that is the reliable check; the background-task footer is not (it does not reliably reflect whether a Monitor is really streaming for this session).

If argument starts with "mode" followed by a mode name (e.g. "mode monitor"):
1. Parse the mode (one of `monitor`, `turn`, `both`, `off`).
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> claude-code "$(pwd)"`
3. Read the `AGMSG-DIRECTIVE` block in the command output and follow it (invoke Monitor or TaskStop as instructed).

If argument is "hook on" (legacy alias):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set turn claude-code "$(pwd)"`
2. Tell the user: "Delivery mode set to 'turn' (legacy hook on behavior). Consider using /__SKILL_NAME__ mode monitor for real-time push."

If argument is "hook off" (legacy alias):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set off claude-code "$(pwd)"`
2. Tell the user: "Delivery mode set to 'off'."

If argument is "config":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/config.sh show`
2. Show the output to the user.

If argument starts with "config set" (e.g. "config set hook.check_interval 30"):
1. Parse key and value from the arguments.
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/config.sh set <key> <value>`

If argument is "version":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/version.sh`
2. Show the output — the installed version (git-describe provenance recorded at install time).

If argument is "reset":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" claude-code`
2. Tell the user the result.

If argument starts with "rename" but not "rename-team":
1. Accept only an explicit user request. Parse either `<team> <old_name> <new_name>`, or `<old_name> <new_name>` only when this agent belongs to exactly one team.
2. Never invent either name. Before execution, repeat the resolved team, old name, and new name and ask the user to confirm. Wait for confirmation.
3. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/rename.sh <team> <old_name> <new_name>`
4. Show the result. For a connected team, the `member_renamed` journal event propagates the rename to other machines.

If argument starts with "rename-team":
1. Accept only an explicit user request. Parse `<old_team> <new_team>`.
2. Never invent either team name. Before execution, repeat the old and new team names and ask the user to confirm. Wait for confirmation.
3. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/rename-team.sh <old_team> <new_team>`
4. Show the result.

If argument starts with "remote connect":
1. Parse the required `--endpoint <url>` and `<team>`, plus optional `--e2ee`.
2. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh connect --endpoint <url> [--e2ee] <team>`
3. Show the output to the user. Plain sync is the default; pass `--e2ee` only when the user explicitly requests end-to-end encryption. The choice is fixed by the first connect.
4. End by showing this copy-paste command for the other machine, with the actual endpoint and team substituted: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh pull --endpoint <actual-url> <actual-team>`

If argument starts with "remote pull":
1. Use this command whenever the user asks to bring in a team that already exists on a server. Never use `join.sh` for that request.
2. Parse the required `--endpoint <url>` and `<team>`, plus optional `--team-id <uuid>`.
3. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh pull --endpoint <url> [--team-id <uuid>] <team>`
4. Show the output to the user.

If argument starts with "remote unlock":
1. Parse `<team>`, one or more `--snapshot <file>` arguments in ascending revision order, exactly one of `--identity <file>` or `--identity-stdin`, and optional `--confirm-digest <sha256>`.
2. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh unlock <team> --snapshot <file> [--snapshot <file> ...] (--identity <file>|--identity-stdin) [--confirm-digest <sha256>]`
3. The snapshot digest must be compared over a separate live channel. Never infer or auto-confirm it. Raw identity material is a permanent secret; when `--identity-stdin` is needed, tell the user to run the command in their own terminal rather than asking them to paste the identity into agent chat.
4. Show the complete result, including the imported-envelope count and engine PID.

If argument starts with "remote status":
1. Parse an optional `<team>` and `--json`.
2. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh status [<team>] [--json]`
3. Show the output to the user.

If argument starts with "remote sync start":
1. Parse the required `<team>`.
2. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh sync start <team>`
3. Show the output to the user.

If argument starts with "remote disconnect":
1. Parse the required `<team>`.
2. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh disconnect <team>`
3. Show the output to the user.

If argument starts with "remote forget":
1. Parse the required `<team>`. This permanently deletes that team's local roster, history, keys, trust, and sync state, but never changes the server.
2. Do not add `--yes` yourself. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh forget <team>`
3. The command requires the user to confirm in their terminal. If this agent has no interactive terminal, show the deletion summary and tell the user to rerun the displayed command directly; never bypass confirmation for them.

If argument starts with "key generate" followed by an optional team name:
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/key.sh generate [<team>]`
2. Show the full output to the user, including the mandatory key-backup notice — do not summarize it away.

If argument starts with "key show":
1. Parse an optional team name and `--reveal-secret`.
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/key.sh show [<team>] [--reveal-secret]`
3. `--reveal-secret` requires a real interactive terminal and is refused in agent mode — if the user wants to reveal a secret, tell them to run it themselves directly in their own terminal rather than through you.
4. Show the output to the user.

If argument starts with "key import" followed by a team name:
1. **Do not ask the user to paste the private identity into this chat, and do not run this command yourself.** This identity is a permanent secret. Tell the user to run this directly in their own terminal:
   ```
   read -rsp 'Identity: ' IDENTITY; echo
   printf '%s' "$IDENTITY" | ~/.agents/skills/__SKILL_NAME__/scripts/key.sh import <team> --identity-stdin
   unset IDENTITY
   ```
2. Ask them to paste back only the command's output (never the identity itself) once it's done.
3. **No advanced/automation env-var path is offered for key import** — not even a pre-existing, before-session variable. An identity file is a permanent secret; always use the human-in-own-terminal flow above.

`key rotate` and device-pairing `key request`/`key approve` are not available yet (they refuse unconditionally and change no state) — if the user asks for either, tell them so rather than attempting to run them.
