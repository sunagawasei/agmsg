# Privacy Policy

**Last updated:** 2026-06-04

This privacy policy describes how the **agmsg** project (the software at https://github.com/fujibee/agmsg, distributed via the Anthropic / OpenAI / community plugin and skill marketplaces, and the `agmsg` npm package) handles user data.

In short: **agmsg does not collect, transmit, or share any user data.** Everything stays on the user's machine.

## What data agmsg handles

When installed, agmsg stores the following on the user's local filesystem only:

- **Team and agent identity registry** — JSON files under `~/.agents/skills/agmsg/teams/<team>/config.json`. Contains team names, agent names within each team, the agent type label (`claude-code`, `codex`, `cursor`), and project paths the user joined from. The user explicitly chooses every value at join time.
- **Messages sent between local agents** — rows in `~/.agents/skills/agmsg/db/messages.db`, an SQLite file. The message body, sender, recipient, team, and timestamp are stored. The user (or the agent acting on their behalf) chooses every value when invoking `send.sh`.
- **Per-session runtime files** — pidfiles, last-checked markers, and the actas exclusivity lock files under `~/.agents/skills/agmsg/run/`. These reference the user's session IDs and process IDs to coordinate hooks.
- **Hook configuration in the user's projects** — agmsg writes per-runtime hook files (e.g. `<project>/.claude/settings.local.json`, `<project>/.codex/hooks.json`, `<project>/.cursor/hooks.json`) when the user picks a delivery mode. These contain absolute paths to the agmsg scripts; they do not contain personal data beyond filesystem paths.

All of the above lives on the user's machine. agmsg has no daemon, no server, and no remote endpoint.

## What agmsg does not do

- **No network requests.** The `install.sh` step uses `curl` to fetch the installer itself, and the optional `agmsg.cc` redirect goes through GitHub. After installation, the runtime makes no outbound requests.
- **No telemetry or analytics.** No usage data, error reports, or counts are sent anywhere.
- **No third-party services.** agmsg integrates with whatever CLI AI agent the user has installed (Claude Code, Codex, Cursor); it does not call those agents' backends itself. Anything the user types to one of those agents is governed by that agent's own privacy policy, not by agmsg.
- **No accounts.** agmsg has no user accounts, no login, no API keys.
- **No data sharing.** Because agmsg never receives data from a remote endpoint and never sends data to one, there is nothing to share, sell, or disclose.

## Where data is stored

All data agmsg writes is on the user's local filesystem under:

- `~/.agents/skills/agmsg/` (the skill directory)
- `<project>/.claude/`, `<project>/.codex/`, `<project>/.cursor/` (per-project hook configs, in the user's own project directories)

The user is solely in control. To delete everything agmsg has stored, run `uninstall.sh` from the repo (which removes the skill directory and per-project hook files) and then delete `~/.agents/skills/agmsg/` if anything remains.

## Inter-agent messages on the same machine

When two agents on the same machine use agmsg to communicate, the message body is written to `messages.db` by the sender and read back by the recipient when their hook fires. The bytes never leave the user's filesystem. Whether the *content* of those messages is sensitive is up to the user — agmsg treats the body as opaque text.

## Children's privacy

agmsg does not collect data from anyone, including children. The software is a developer tool intended for use by users 13 and older in accordance with the underlying agent CLIs (Claude Code, Codex, etc.) and their respective terms.

## Changes to this policy

If agmsg ever begins to collect or transmit data, this policy will be updated and the change announced in the project repository's [`CHANGELOG`](https://github.com/fujibee/agmsg/commits/main) or release notes. The current version of this policy lives at:

https://github.com/fujibee/agmsg/blob/main/PRIVACY.md

## Contact

Questions or concerns about this policy can be raised by:

- Opening an issue at https://github.com/fujibee/agmsg/issues, or
- Emailing the maintainer at **fujibee@gmail.com**.

## License

The agmsg project itself is MIT-licensed. See [`LICENSE`](https://github.com/fujibee/agmsg/blob/main/LICENSE).
