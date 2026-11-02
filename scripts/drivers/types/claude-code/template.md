<!-- Claude Code overlay for the shared SKILL.md. -->

<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
  5. **REQUIRED — Do NOT skip this step.** Choose how incoming messages reach this agent. Show this screen every time (a new join, a new seat added by someone already using agmsg, and when the mode is changed). First run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg daemon offer __AGENT_TYPE__`; it only reads and prints one line:
     - `agmsgd=available`: ask the user to pick one, in this order:
       1. `agmsgd` — notices delivered directly by a background service (recommended). Choosing it registers a background service that starts at login; `agmsg daemon disable` stops and removes it. Empty input means this one.
       2. `monitor (legacy)` — the Claude Code Monitor tool streams the inbox (the `monitor` mode value).
       3. `turn`, 4. `both`, 5. `off` — as before.
     - `agmsgd=on`: do not ask which to use. Say "agmsgd is on: notices are delivered directly" and ask only whether to keep using it or switch to `monitor (legacy)`.
     - `agmsgd=not-running reason=...`: agmsgd is turned on but is not running, so do not say notices are delivered directly. Say so with the reason and ask whether to start it (`agmsg delivery agmsgd` starts it) or switch to `monitor (legacy)`.
     - `agmsgd=unavailable reason=...`: do not offer agmsgd; say the reason in one line, then ask for `monitor (legacy)`, `turn`, `both`, or `off` (empty input means `monitor`).

     To apply the choice, run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery <choice> --type __AGENT_TYPE__ --project "$(pwd)"` with `<choice>` = `agmsgd`, `monitor`, `turn`, `both` or `off` (`monitor (legacy)` is the value `monitor`) and show its output and follow the printed `AGMSG-DIRECTIVE` block:
     - `agmsgd` turns the background service on (`daemon enable`) and records the choice; the project then receives through agmsgd only, with no Monitor fallback, and a stopped agmsgd is reported with how to restart it. If it fails, say so and offer the other choices.
     - Keep using agmsgd (it is on or turned on but not running): run `agmsg delivery agmsgd` the same way; it also records that this project uses agmsgd.
     - `monitor (legacy)` (and `turn`, `both`, `off`) is a real opt-out: the CLI records that this project does not use agmsgd, so agmsgd stops delivering here and the project keeps the old path. agmsgd stays on for the install's other projects; when it says so, pass on its line that `agmsg daemon disable` turns agmsgd off for all of them.
<!-- /agmsg:slot delivery -->

<!-- agmsg:slot execute-extra -->
**Ensure monitor is running first.** What decides is `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery status --type __AGENT_TYPE__ --project "$(pwd)"`, its `this project:` line (not the hooks file, and not a leftover Monitor from an earlier session). Keep one persistent `watch.sh` task for this session only when that line says `monitor (legacy)` or `both`. Start no Monitor when it says `agmsgd`, or when SessionStart or `actas` reported native delivery (`agmsgd is running and will deliver to this session directly`). Switch that watcher when `actas` changes the active role.

If asked, in ordinary language and in either English or Japanese, to re-arm this session's own agmsg monitor (no fixed trigger word — read the request as it is phrased): invoke Monitor with the standard command and description for this seat, and say nothing else.

If asked to re-arm every Claude Code seat in the team together (not just this session's own — no dedicated command for this, do it through poke: #1321): run `~/.agents/skills/__SKILL_NAME__/scripts/team.sh <team> --json`, select the rows whose `type` is `claude-code` and whose `delivery` is `monitor` or `both`, deduplicated by member name. Whole team — never narrow this to your own project. For each selected seat, in turn with a gap of a few seconds between seats (poking them all at once starts every seat's model turn in the same instant and risks rate limits): write a one-line message asking that seat to re-arm its own agmsg monitor — phrase it in whoever asked's own words, or something equivalent — to a file, then `~/.agents/skills/__SKILL_NAME__/scripts/poke.sh <team> <seat> --retries 5 --retry-delay 2 --backoff exponential --body-file <path>`. A seat whose input box was still busy after every retry (poke exits 14) could not be reached this way; name it in your report rather than silently skipping it.

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

Four entries are needed because a rule matches the command string as written, and these scripts are invoked both as `~/...` and as an absolute path, with or without an explicit `bash` prefix. Replace `/Users/<you>` with the user's home directory.

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

**Session-team mode (`delivery.session_team`).** When this config is enabled, your identity is your OWN per-session team `s-$CLAUDE_CODE_SESSION_ID` (agent `claude`). `whoami.sh` already returns it, so `$TEAM`/`$AGENT` resolve to the session team with no extra step, and each Claude session is fully isolated — you never see other sessions' traffic. The session's codex worker is started lazily: **before the first `send`/`ask` to codex, run** `~/.agents/skills/__SKILL_NAME__/scripts/ensure-codex.sh "$(pwd)"`. It brings up a headless codex in your session team (and is a no-op when the mode is off, so it is always safe to run first). On `--continue`/`--resume` the team name is unchanged (same session id), but the previous generation's team is removed when its owner dies, so the resumed session starts with an empty team: prior messages and history are not available.

**IMPORTANT — cross-session isolation.** `$TEAM` for `send.sh`/`ask` MUST come from `whoami.sh` output (the Identity section above). Never derive the team from pidfiles, process listings, or `ls run/codex-bridge.*` — other sessions may have live bridges whose team names look similar, and using the wrong team would leak your messages into another session. As a backstop, `send.sh` refuses a send INTO another session's private team (`s-<id>`) when it is not this session's own; project-team sends are unaffected, and a deliberate cross-session send needs `AGMSG_ALLOW_CROSS_TEAM=1`. `ensure-codex.sh` also prints `ensure-codex: … in team '<name>'` on its session-team success paths so you can confirm it targeted your session's team.

**send vs ask — pick by whether you expect a reply.** Use `ask` for any message
where you want an answer back (questions, requests, consultations, code-review
asks). Use `send` for one-way traffic (notifications, acknowledgements,
fire-and-forget, control). The difference is busy-keep: `ask` blocks until the
reply lands so the session keeps "running"; `send` returns immediately.

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
If argument starts with "send" and `<to_agent>` is `codex`, first run `~/.agents/skills/__SKILL_NAME__/scripts/ensure-codex.sh "$(pwd)"` (lazily starts this session's codex in session-team mode; no-op otherwise), then follow the normal send flow.

<!-- /agmsg:slot execute-extra -->

<!-- agmsg:slot actas -->
If argument starts with "actas" followed by an agent name (e.g. "actas alice"):
1. Parse the new role name. If none was given (e.g. bare "actas", or the user asks you to suggest one), run `~/.agents/skills/__SKILL_NAME__/scripts/team.sh <team>` for each TEAM to see the current roster. Look for a naming convention already in play (e.g. a shared base name with role and number suffixes (`<base>-<role><n>`), or names derived from the team name) and, when one exists, propose 2-3 unused names that extend it; otherwise propose 2-3 short, distinctive identity names (not a bare tool-type label). Either way, names must not collide with the roster. Ask the user to pick one or type their own before continuing.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/identities.sh "$(pwd)" __AGENT_TYPE__` to see whether the role is already registered for this (project, type).
3. If the name does not appear in the output, join under the existing team. Read TEAMS from the in-session whoami state (it may be a single team or comma-separated). For a single team, run `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> __AGENT_TYPE__ "$(pwd)"`. For multiple teams, ask the user which team to join the new role into, then run join.sh for that team.
4. **Pre-flight claim** the actas exclusivity lock so this role isn't already owned by another live session: `~/.agents/skills/__SKILL_NAME__/scripts/actas-claim.sh "$(pwd)" __AGENT_TYPE__ <name> "$CLAUDE_CODE_SESSION_ID"`. Read the `status=` line of the output:
    - `status=ok ...`: proceed to step 5.
    - `status=held team=<team> owner=<sid>`: another live session currently owns `<name>` in `<team>`. Tell the user: "Cannot actas as `<name>` — it is held by session `<sid>` in team `<team>`. Run `/__SKILL_NAME__ drop <name>` in that session first, then retry." Then abort — do NOT touch the running Monitor.
    - `status=not_registered`: shouldn't happen if step 3 ran; treat as an error.
5. **Switch receive too — exclusive role mode.**
   a. Find this session's agmsg watch Monitor task: a task in TaskList whose description begins with "agmsg inbox stream", or the task_id returned by a Monitor call you made earlier in this conversation. Not every environment lists Monitor tasks in TaskList, so an empty list does not mean none is running.
   b. **If you have such a task_id**: TaskStop it.
   c. **If you have none** (typical when /__SKILL_NAME__ actas runs as the first command of a fresh session — SessionStart hasn't fired the Monitor directive yet, or you're invoking actas before the agent acted on it): skip TaskStop. Do NOT attempt TaskStop with a guessed or empty task_id — it will fail with "Invalid tool parameters" and confuse the flow. Starting a new watcher for this session in step d replaces any previous one.
   d. **If the step 4 output had a `delivery=native` line**: agmsgd now delivers to this session directly, so start no Monitor and skip the rest of this step. **If it had a `delivery=agmsgd state=stopped` line**: this project receives through agmsgd only, which is not running; start no Monitor, skip the rest of this step, and tell the user that agmsgd is not running (give the `reason=` value), that unread messages are kept and this session's destination is recorded so agmsgd delivers to it once started, and that `agmsg daemon start` brings it back. **If it had a `delivery=agmsgd state=blocked` line**: start no Monitor either, skip the rest of this step, and tell the user the native channel cannot be used (give the `reason=` value) and to run `agmsg doctor`. Otherwise run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status __AGENT_TYPE__ "$(pwd)"` and read its **first line**.
      - **`mode: agmsgd ...`**: this project receives through agmsgd, so start no Monitor and leave it stopped. If the text says agmsgd is not confirmed running, tell the user and give the reason it names.
      - **`mode: monitor` or `mode: both`**: invoke a fresh Monitor, regardless of whether step b or c applied:
        - command: `~/.agents/skills/__SKILL_NAME__/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" __AGENT_TYPE__ <name> --max-seconds=1500`
        - description: `agmsg inbox stream (acting as <name>)`
        - persistent: true
        - timeout_ms: 1800000

        This watch renews itself. A little before the 30-minute cap it prints one line on its own and exits: on `agmsg watch: re-arm - ...`, invoke Monitor again with exactly the command and description that line names (persistent: true, timeout_ms: 1800000), silently — no message to the user, no "re-armed", no acknowledgement, no summary, since announcing it every 30 minutes wastes tokens for no benefit; on `agmsg watch: stopping - ...`, do not re-arm it. If the watch is instead killed at the cap and no such line arrived (an agmsg install from before this), re-arm it only when the expiry notification says it delivered something.
      - **`mode: turn`**: leave it stopped, silently. `has_st=1` is the one case `delivery.sh` can actually confirm was a deliberate choice — someone configured turn-based delivery for this project — so `actas` starting nothing here needs no explanation.
      - **`mode: off (no agmsg delivery hooks installed for this project)`**: leave it stopped (`actas` must not start automatic delivery a project wasn't configured for), but **do not treat this as silently deliberate**. `delivery.sh` cannot tell whether someone ran `mode off` here or this project was simply never configured — both leave the exact same settings file (#687 review round 3). **Tell the user** — e.g. "agmsg delivery hooks are not installed for this project; automatic delivery remains stopped. Run `/__SKILL_NAME__ mode <choice>` if you want to configure it." Keep it matter-of-fact, not a warning. Do not report `actas` as complete without saying this.
      - **`mode: off (unrecognized: ...)`**: leave it stopped too (same rule — do not guess a mode), but this is a stronger case than the no-hooks-installed one above: `delivery.sh` could not even find or read a settings file for this project, most often because the working directory does not match how the project was actually registered. **Tell the user explicitly** — e.g. "agmsg could not find a delivery configuration for this project at `<path from the message>` — delivery is stopped, but this may mean the project isn't registered here rather than that it was deliberately turned off. Check the path, or run `/__SKILL_NAME__ mode <choice>` to configure it explicitly." Do not report `actas` as complete without saying this — a silent stop here is indistinguishable from the other off cases and is what let this go unnoticed before (#687).
   The 4th argument to `watch.sh` restricts the subscription to messages addressed to `<name>` only — other roles' inbound messages stop reaching this session until another `actas` or session end.
6. Set the session's active FROM to `<name>` — use `<name>` in every `send.sh` call for the rest of this session.
7. Tell the user: "Now acting as `<name>`. Sends use `<name>` as from; receive restricted to `<name>` only."
8. **Only if this session was NOT launched via `spawn`** — check the environment variable `AGMSG_SPAWNED` (e.g. `printenv AGMSG_SPAWNED`): `spawn` exports `AGMSG_SPAWNED=1` and already named the session `<team>-<agent>` via `-n`, so when it is set, **skip this tip entirely**. When it is UNSET (a human typed `claude` then actas'd, so the session has no convention name), additionally suggest to the user: "Tip: rename this session to `<team>-<name>` with `/rename <team>-<name>` so it's easy to find in the `/resume` picker and stays labeled after a restart." `/rename` is a user-typed slash command — you cannot invoke it yourself, so only suggest it.
9. **Confirm the Monitor actually attached** — only when step 5d invoked a fresh Monitor (`mode: monitor` or `mode: both`): confirm the Monitor call from step 5d started (it returned a task id rather than an error). TaskList may list this task, but not every environment does (the desktop app's Code tab runs the Monitor and delivers its events without listing it), so a task missing from TaskList is not a failure: judge by the Monitor call starting and its events arriving. The background-task footer is not a reliable check either. If the Monitor call failed, retry the invocation from step 5d once. If it still fails after the retry, tell the user `actas` completed but delivery could not be confirmed as attached, and do not describe delivery as active.
<!-- /agmsg:slot actas -->

<!-- agmsg:slot drop -->
If argument starts with "drop" followed by an agent name (e.g. "drop alice"):
1. Parse the role name.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" __AGENT_TYPE__ <name> "$CLAUDE_CODE_SESSION_ID"` to remove only that role's registration for this project. If the role has no other registrations left, reset.sh also drops it from the team config. The 4th argument releases any actas exclusivity locks this session held on the role so peers can pick it up immediately (see #62).
3. If the session's active FROM was `<name>`, clear that state. Then:
   a. Find this session's agmsg watch Monitor task: a task in TaskList whose description begins with "agmsg inbox stream", or the task_id returned by a Monitor call you made earlier in this conversation. An empty TaskList does not mean none is running.
   b. **If you have such a task_id**: TaskStop it.
   c. **If you have none**: skip TaskStop. Do NOT attempt TaskStop with a guessed or empty task_id.
   d. Run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status __AGENT_TYPE__ "$(pwd)"` and read its **first line**.
      - **`mode: agmsgd ...`**: this project receives through agmsgd, so start no Monitor and leave it stopped. If the text says agmsgd is not confirmed running, tell the user and give the reason it names.
      - **`mode: monitor` or `mode: both`**: invoke a fresh Monitor with the default subscription (no `actas` name filter — receives every (team, agent) pair currently registered for this project that isn't held by another session):
        - command: `~/.agents/skills/__SKILL_NAME__/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" __AGENT_TYPE__ --max-seconds=1500`
        - description: `agmsg inbox stream`
        - persistent: true
        - timeout_ms: 1800000

        This watch renews itself. A little before the 30-minute cap it prints one line on its own and exits: on `agmsg watch: re-arm - ...`, invoke Monitor again with exactly the command and description that line names (persistent: true, timeout_ms: 1800000), silently — no message to the user, no "re-armed", no acknowledgement, no summary, since announcing it every 30 minutes wastes tokens for no benefit; on `agmsg watch: stopping - ...`, do not re-arm it. If the watch is instead killed at the cap and no such line arrived (an agmsg install from before this), re-arm it only when the expiry notification says it delivered something.
      - **`mode: turn`**: leave it stopped, silently — the one case `delivery.sh` can confirm was deliberate.
      - **`mode: off (no agmsg delivery hooks installed for this project)`**: leave it stopped, but say so — same reasoning as the `actas` step this mirrors: this state is indistinguishable from "never configured" (#687 review round 3), so do not report it as deliberate. Do not report the drop as complete without mentioning it.
      - **`mode: off (unrecognized: ...)`**: leave it stopped, but say so with the stronger diagnostic — same reasoning as the `actas` step this mirrors (#687). Do not report the drop as complete without mentioning it.
4. Tell the user: "Dropped role `<name>` from this project."
<!-- /agmsg:slot drop -->

<!-- agmsg:slot spawn -->
If argument starts with "spawn" (e.g. "spawn codex reviewer", "spawn claude-code alice --window"):
1. Parse `<type>` (a spawnable agent type), `<name>`, and any options (`--boot-prompt <text>`, `--project <path>`, `--team <team>`, `--window`, `--split h|v`, `--terminal <template>`, `--no-wait`, `--ready-timeout <secs>`, `--model <id>`, `--fresh`).
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/spawn.sh <type> <name> --project "$(pwd)" [options]`
   - `spawn.sh` pre-joins `<name>`, then opens a new pane or window through the terminal driver and launches the target CLI with `/__SKILL_NAME__ actas <name>` as its initial prompt. `--boot-prompt` appends a first task to that prompt. Which terminal that is is the driver's decision, never something to name here.
   - By default it blocks until a spawned Claude Code agent's watcher attaches and prints `status=ready`; `--no-wait` returns immediately. A spawned Codex agent skips the readiness wait: it has no spawn-time readiness handshake (that is separate from how it receives messages).
   - It refuses early when `<name>` is already held by another live session, the target CLI is missing, the project path is invalid, or the terminal driver has nowhere to place it.
3. Show the script's output. Do not TaskStop or relaunch this session's own Monitor; spawn affects a separate agent.

If argument starts with "despawn" (e.g. "despawn reviewer", "despawn alice --force"):
1. Parse `<name>` and any options (`--force`, `--timeout <secs>`). `despawn` tears down a member previously spawned by this session.
2. Determine which team `<name>` belongs to, then run:
   `~/.agents/skills/__SKILL_NAME__/scripts/despawn.sh <team> $AGENT <name> [--force] [--timeout <secs>]`
   - The default graceful path sends a `ctrl:despawn` message; the member's watcher drops its role and closes its spawned pane, then `despawn` waits for the lock to release.
   - If the member is Codex and has no watcher (it never holds an actas lock), or graceful teardown times out, use `--force` to tear down the recorded pane/window and drop the registration directly.
3. Show the script's output. Do not TaskStop or relaunch this session's own Monitor.
   - **claude-code headless**: `--headless` runs one-shot `claude -p` turns through a persistent no-terminal bridge. Every layout uses a neutral scratch cwd and generated fail-closed sandbox settings. The default consultant has no repo `--add-dir`; `--implementer` grants repo Edit/Write; `--reviewer` grants repo read while denying repo writes and credential-targeted reads. Set `spawn.claude_headless=true` for the default, `spawn.claude_reviewer=true` for reviewer default, or `spawn.claude_implementer.<name>=true` per worker. Model, effort, and turn timeout use `spawn.claude_model.<name>`, `spawn.claude_effort.<name>`, and `spawn.claude_turn_timeout.<name>`.
   - **claude-code reviewer add-dirs**: `spawn.claude_inherit_add_dirs=true` opts reviewers into persisted `permissions.additionalDirectories`; `spawn.claude_inherit_add_dirs.<name>` overrides it per worker. The default is off, so reviewer read scope is never widened silently.
   - **codex headless**: `--headless` runs codex as a no-terminal bridge worker (no window) that talks over the bus — useful as a persistent reviewer. Its cwd is a neutral scratch dir under `run/` and it is sandboxed to read anywhere but write only agmsg's `db/teams/run` (`--project` here selects the team/subscription, not codex's cwd). Setting config `spawn.codex_headless=true` makes every codex spawn headless by default; pass `--interactive` to force a one-off TUI.
   - **codex reviewer**: `--reviewer` (headless only; default from config `spawn.codex_reviewer`) makes codex's cwd the target repo under a read-only permission profile — it can explore the repo but only write agmsg's `db/teams/run`, and unrelated paths (e.g. `~/.ssh`) stay unreadable. Set config `spawn.codex_inherit_add_dirs=true` to additionally grant the reviewer READ access to the directories this Claude session was given via `/add-dir` (`permissions.additionalDirectories` in the project's `.claude/settings{,.local}.json`), so codex sees the same out-of-repo dirs you do. Off by default (it widens the read scope); the spawn output lists any inherited read roots. Only persisted add-dirs are picked up — directories added with `/add-dir` mid-session aren't written to settings, so re-add them there to share with codex.
   - **codex implementer**: `--implementer` (headless only; default from config `spawn.codex_implementer.<name>`) makes codex's cwd the target repo under workspace-write — the repo is WRITABLE, for implementation work delegated to codex. Mutually exclusive with `--reviewer`. Replies go through agmsg's `db/teams/run` as usual; network stays off.
   - **cursor headless**: a headless cursor is always a read-only reviewer in `--project` (no scratch/consultant mode; `--reviewer` and `--implementer` are rejected). Read-only is enforced via a scratch `.cursor/cli.json` (config `spawn.cursor_readonly`, default on). Tear down with `despawn --force`.
<!-- /agmsg:slot spawn -->

<!-- agmsg:slot mode -->
If argument is "delivery" (or its alias "mode") with nothing after it, run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery status --type __AGENT_TYPE__ --project "$(pwd)"`. It shows both the install-wide agmsgd state (for example "delivery: agmsgd (on) — notices are delivered directly") and this project's own delivery (for example "this project: agmsgd"). Show the output to the user, and if it says `mode: monitor` (or `both`), say explicitly that this reports project *configuration* only — it does not prove the runtime Monitor task is attached in the current session. To confirm the runtime state, look for a Monitor whose description begins with `agmsg inbox stream` (after an `actas` it reads `agmsg inbox stream (acting as <name>)`). TaskList may list this task, but not every environment does (the desktop app's Code tab runs the Monitor and delivers its events without listing it), so a task missing from TaskList is not a failure: judge by the Monitor call starting and its events arriving. The background-task footer is not a reliable check either. When agmsgd is off but available, tell the user that `/agmsg delivery agmsgd` turns direct delivery on.

For `delivery agmsgd|monitor|turn|both|off` (and the same values after the alias `mode`), run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery <value> --type __AGENT_TYPE__ --project "$(pwd)"` and follow its `AGMSG-DIRECTIVE` block. `agmsgd` runs `daemon enable` and records the choice (no Monitor fallback); the other values are exactly `delivery.sh set <value>`. `monitor` is always shown as `monitor (legacy)` on the choice screen, but its value stays `monitor`. Legacy `hook on` maps to `turn`; `hook off` maps to `off`.
<!-- /agmsg:slot mode -->
