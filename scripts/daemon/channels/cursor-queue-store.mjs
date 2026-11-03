// Daemon-side tables and roster/record readers for the cursor channel. Message
// stores are reused read-only from codex-queue-store.mjs; nothing here writes
// message data or read cursors.

import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { roleSessionPath } from "./codex-queue-store.mjs";

export const CURSOR_CHANNEL_SCHEMA = `
CREATE TABLE IF NOT EXISTS beta_cursor_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  seat TEXT NOT NULL,
  herdr_locator TEXT NOT NULL,
  up_to TEXT NOT NULL,
  nonce TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'confirmed', 'expired')),
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS beta_cursor_queue_one_pending
  ON beta_cursor_queue(seat) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS beta_cursor_queue_latest
  ON beta_cursor_queue(seat, id DESC);
CREATE TABLE IF NOT EXISTS beta_cursor_seat (
  seat TEXT PRIMARY KEY,
  herdr_locator TEXT,
  state TEXT NOT NULL CHECK (state IN ('addressable', 'unaddressable', 'blocked')),
  reason TEXT NOT NULL,
  checked_at TEXT NOT NULL
);
`;

export function ensureCursorChannelSchema(db) {
  db.exec("BEGIN IMMEDIATE;");
  try {
    db.exec(CURSOR_CHANNEL_SCHEMA);
    db.exec("COMMIT;");
  } catch (error) {
    try { db.exec("ROLLBACK;"); } catch { /* preserve the schema error */ }
    throw error;
  }
}

// "<socket-path>:wN:pX". The socket path may itself contain ':' or spaces, so
// the pane half is taken from the end, as ops.sh's _herdr_sock_of does.
export function parseHerdrLocator(locator) {
  const match = /^(.+):(w[0-9A-Za-z]+:p[0-9A-Za-z]+)$/.exec(locator ?? "");
  if (!match || !isAbsolute(match[1])) return null;
  return { socketPath: match[1], pane: match[2] };
}

export function readCursorRoleSession(runDir, team, agent) {
  const path = roleSessionPath(runDir, team, agent);
  let stat;
  try {
    stat = lstatSync(path);
  } catch (error) {
    if (error?.code === "ENOENT") return { state: "absent" };
    return { state: "unreadable", reason: "role_session_read_failed" };
  }
  if (!stat.isFile() || stat.isSymbolicLink()) return { state: "unreadable", reason: "role_session_not_regular_file" };
  try {
    const fields = Object.create(null);
    for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
      const at = line.indexOf("=");
      if (at < 1) continue;
      const key = line.slice(0, at);
      if (!(key in fields)) fields[key] = line.slice(at + 1);
    }
    return {
      state: "present",
      record: {
        team: fields.team ?? "",
        agent: fields.agent ?? "",
        type: fields.type ?? "",
        project: fields.project ?? "",
        herdr_locator: fields.herdr_locator ?? "",
        herdr_terminal_id: fields.herdr_terminal_id ?? "",
        cursor_conversation_id: fields.cursor_conversation_id ?? "",
        // Why the driver published no destination (it clears the herdr fields then).
        messaging_blocked: /^[a-z_]{1,64}$/.test(fields.messaging_blocked ?? "") ? fields.messaging_blocked : "",
      },
    };
  } catch {
    return { state: "unreadable", reason: "role_session_read_failed" };
  }
}

// Same walk as listClaudeCodeRegistrations, filtered on type "cursor". A team
// whose roster cannot be read is listed under `skipped` and hides no other.
export function listCursorRegistrations(teamsDir) {
  let entries;
  try {
    entries = readdirSync(teamsDir, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return { state: "ok", seats: [], skipped: [] };
    return { state: "unreadable", reason: "team_roster_unreadable" };
  }
  const seats = [];
  const skipped = [];
  for (const entry of entries) {
    if (entry.isSymbolicLink()) {
      skipped.push({ team: entry.name, reason: "team_roster_symlink" });
      continue;
    }
    if (!entry.isDirectory()) continue;
    let config;
    try {
      const stat = lstatSync(join(teamsDir, entry.name, "config.json"));
      if (!stat.isFile() || stat.isSymbolicLink()) {
        skipped.push({ team: entry.name, reason: "team_roster_symlink" });
        continue;
      }
      config = JSON.parse(readFileSync(join(teamsDir, entry.name, "config.json"), "utf8"));
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      skipped.push({ team: entry.name, reason: "team_roster_malformed" });
      continue;
    }
    if (!config || typeof config !== "object" || !config.agents || typeof config.agents !== "object" || Array.isArray(config.agents)) {
      skipped.push({ team: entry.name, reason: "team_roster_malformed" });
      continue;
    }
    for (const [agent, value] of Object.entries(config.agents)) {
      const regs = value && Array.isArray(value.registrations) ? value.registrations : [];
      if (regs.some((registration) => registration?.type === "cursor")) {
        seats.push({ team: entry.name, agent, teamConfig: config });
      }
    }
  }
  return { state: "ok", seats, skipped };
}
