// Polls the existing message stores and nudges registered cursor-agent seats
// by submitting one prompt to their herdr pane. It never writes message data or
// read cursors; a completed `herdr agent prompt` advances only this seat's
// notification cursor (at-least-once). Same shape as claude-code-queue.mjs.
//
// The herdr instance comes from the seat's own role-session record, never from
// the daemon's environment: the daemon is not a child of any herdr instance.

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import { assertPollActive, pollSignal, SEAT_DEADLINE_MS } from '../poll-deadline.mjs';
import { createSeatPoller } from '../seat-poll.mjs';
import { logLine } from "../log.mjs";
import { optedOutOfAgmsgd } from "./delivery-choice.mjs";
import { withImmediateTransaction } from "../db.mjs";
import {
  messageStorePath,
  openMessageStore,
  readStorageDriver,
  readUnreadSnapshot,
} from "./codex-queue-store.mjs";
import { sameProject, seatKey } from "./codex-queue.mjs";
import { checkSocketOwnership, inboxNudge, newNonce } from "./claude-code-queue-io.mjs";
import {
  listCursorRegistrations,
  parseHerdrLocator,
  readCursorRoleSession,
} from "./cursor-queue-store.mjs";

const HERDR_TIMEOUT_MS = 5_000;
const KILL_GRACE_MS = 1_000;
const MAX_OUTPUT_CHARS = 256 * 1024;
const SENDABLE_STATUS = new Set(["idle", "done"]);
const BUSY_STATUS = new Set(["working", "blocked"]);

function signalGroup(child, signal) {
  if (process.platform !== "win32" && Number.isInteger(child.pid) && child.pid > 1) {
    try { process.kill(-child.pid, signal); return; } catch (error) { if (error?.code !== "ESRCH") return; }
  }
  try { child.kill(signal); } catch { /* close remains the authority */ }
}

// Runs one herdr command against exactly one instance. HERDR_* inherited from
// the daemon is dropped so only the record's socket can pick the target.
export async function runHerdr({
  executable, socketPath, args, timeoutMs = HERDR_TIMEOUT_MS, signal, env = process.env, spawnProcess = spawn,
}) {
  if (signal?.aborted) return { kind: "cancelled" };
  const childEnv = Object.fromEntries(Object.entries(env).filter(([key]) => !key.startsWith("HERDR_") && key !== "PATH"));
  childEnv.PATH = `${dirname(executable)}:/usr/bin:/bin`;
  childEnv.HERDR_SOCKET_PATH = socketPath;
  let child;
  try {
    child = spawnProcess(executable, args, {
      env: childEnv, stdio: ["ignore", "pipe", "pipe"], windowsHide: true, detached: process.platform !== "win32",
    });
  } catch (error) {
    return { kind: "failed", reason: `spawn_failed:${error.code ?? "unknown"}` };
  }
  let stdout = "";
  child.stdout?.on("data", (chunk) => { if (stdout.length < MAX_OUTPUT_CHARS) stdout += chunk.toString("utf8"); });
  child.stderr?.resume();
  let settle;
  const closed = new Promise((resolve) => {
    settle = resolve;
    child.once("error", (error) => resolve({ error }));
    child.once("close", (code, sig) => resolve({ code, sig }));
  });
  let timedOut = false;
  let aborted = false;
  const timers = [];
  const kill = () => {
    signalGroup(child, "SIGKILL");
    child.stdout?.destroy();
    child.stderr?.destroy();
    child.unref?.();
    settle({ deadline: true });
  };
  const onAbort = () => {
    aborted = true;
    signalGroup(child, "SIGTERM");
    timers.push(setTimeout(kill, KILL_GRACE_MS));
  };
  signal?.addEventListener("abort", onAbort, { once: true });
  timers.push(setTimeout(() => {
    timedOut = true;
    signalGroup(child, "SIGTERM");
    timers.push(setTimeout(kill, KILL_GRACE_MS));
  }, timeoutMs));
  const result = await closed;
  for (const timer of timers) clearTimeout(timer);
  signal?.removeEventListener("abort", onAbort);
  if (aborted) return { kind: "cancelled" };
  if (timedOut) return { kind: "failed", reason: "timeout" };
  if (result.error) return { kind: "failed", reason: `spawn_failed:${result.error.code ?? "unknown"}` };
  if (result.code !== 0) return { kind: "failed", reason: `exit_${result.code ?? result.sig ?? "unknown"}` };
  return { kind: "ok", stdout };
}

// The shape was measured from `herdr agent list`; anything else is an error,
// never an empty list that would silently disable delivery.
export function parseAgentList(stdout) {
  let parsed;
  try { parsed = JSON.parse(stdout); } catch { return null; }
  const result = parsed?.result;
  if (result?.type !== "agent_list" || !Array.isArray(result.agents)) return null;
  if (!result.agents.every((agent) => agent && typeof agent === "object" && !Array.isArray(agent))) return null;
  return result.agents;
}

function registrationProjects(teamConfig, agent) {
  const registrations = teamConfig?.agents?.[agent]?.registrations;
  return Array.isArray(registrations)
    ? registrations.filter((item) => item?.type === "cursor").map((item) => item.project).filter((value) => typeof value === "string" && value)
    : [];
}

// `confirmed` means the herdr prompt call completed.
function latestNotifiedCursor(db, seat) {
  const row = db.prepare(`
    SELECT up_to FROM beta_cursor_queue WHERE seat = ? AND state = 'confirmed'
    ORDER BY id DESC LIMIT 1
  `).get(seat);
  return row?.up_to ?? "";
}

function saveSeat(db, { seat, herdrLocator = null, state, reason = "" }, now) {
  assertPollActive();
  withImmediateTransaction(db, () => {
    db.prepare(`
      INSERT INTO beta_cursor_seat (seat, herdr_locator, state, reason, checked_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(seat) DO UPDATE SET herdr_locator=COALESCE(excluded.herdr_locator, beta_cursor_seat.herdr_locator),
        state=excluded.state, reason=excluded.reason, checked_at=excluded.checked_at
    `).run(seat, herdrLocator, state, reason, new Date(now()).toISOString());
  });
}

function setQueueState(db, id, state) {
  assertPollActive();
  withImmediateTransaction(db, () => {
    db.prepare("UPDATE beta_cursor_queue SET state = ? WHERE id = ? AND state = 'pending'").run(state, id);
  });
}

function createSendAttempt(db, { seat, herdrLocator, upTo, nonce, expectedOpGen }, now) {
  assertPollActive();
  let rowId;
  withImmediateTransaction(db, () => {
    const intent = db.prepare("SELECT desired, op_gen FROM daemon_intent").get();
    if (intent?.desired !== "on" || intent.op_gen !== expectedOpGen) {
      throw new Error("daemon_intent_changed");
    }
    // A row left pending by an interrupted poll must not block a new attempt.
    db.prepare("UPDATE beta_cursor_queue SET state = 'expired' WHERE seat = ? AND state = 'pending'").run(seat);
    const result = db.prepare(`
      INSERT INTO beta_cursor_queue (seat, herdr_locator, up_to, nonce, state, created_at)
      VALUES (?, ?, ?, ?, 'pending', ?)
    `).run(seat, herdrLocator, upTo, nonce, new Date(now()).toISOString());
    rowId = Number(result.lastInsertRowid);
  });
  return rowId;
}

function storagePaths(installRoot, env) {
  return {
    storageDir: env.AGMSG_STORAGE_PATH || join(installRoot, "db"),
    configPath: env.AGMSG_CONFIG || join(homedir(), ".agents", "agmsg", "config.json"),
  };
}

export function createCursorQueueChannel({
  db,
  installRoot,
  expectedOpGen,
  env = process.env,
  seatDeadlineMs = SEAT_DEADLINE_MS,
  timeoutMs = HERDR_TIMEOUT_MS,
  now = Date.now,
  log = (message) => logLine(installRoot, message),
  listSeats = listCursorRegistrations,
  readSession = readCursorRoleSession,
  readDriver = readStorageDriver,
  openStore = openMessageStore,
  readSnapshot = readUnreadSnapshot,
  run = runHerdr,
  socketAlive = checkSocketOwnership,
}) {
  let stopped = false;
  let rosterReasons = new Map();
  let activePoll = null;
  let activePollSignal;
  let resumeAfter;
  const seatPoller = createSeatPoller({
    db, installRoot, channel: 'cursor', log, timeoutMs: seatDeadlineMs,
    saveTimeout: (seat, reason) => saveSeat(db, { seat, state: 'blocked', reason }, now),
  });

  async function fetchList(executable, socketPath) {
    const outcome = await run({ executable, socketPath, args: ["agent", "list"], timeoutMs, signal: pollSignal(), env });
    if (outcome.kind === "cancelled") return outcome;
    if (outcome.kind !== "ok") return { kind: "failed", reason: `herdr_list_failed:${outcome.reason}` };
    const agents = parseAgentList(outcome.stdout);
    return agents ? { kind: "ok", agents } : { kind: "failed", reason: "herdr_list_unrecognized" };
  }

  // Cached per instance per poll cycle: only for deciding whether to send.
  // The send itself is always re-checked against a fresh list.
  async function agentList(cycle, executable, socketPath) {
    if (!cycle.lists.has(socketPath)) cycle.lists.set(socketPath, fetchList(executable, socketPath));
    const result = await cycle.lists.get(socketPath);
    if (result.kind === "cancelled") cycle.lists.delete(socketPath);
    return result;
  }

  // The listed pane must be the record's agent: cursor, project, terminal.
  function matchPane(agents, target, record) {
    const matches = agents.filter((entry) => entry.pane_id === target.pane);
    if (matches.length === 0) return { reason: "herdr_pane_missing", state: "unaddressable" };
    if (matches.length > 1) return { reason: "herdr_list_unrecognized", state: "blocked" };
    const pane = matches[0];
    if (typeof pane.agent !== "string" || typeof pane.cwd !== "string" || typeof pane.terminal_id !== "string" || typeof pane.agent_status !== "string") {
      return { reason: "herdr_list_unrecognized", state: "blocked" };
    }
    if (pane.agent !== "cursor") return { reason: "herdr_wrong_agent", state: "blocked" };
    if (!sameProject(pane.cwd, record.project)) return { reason: "herdr_wrong_cwd", state: "blocked" };
    if (pane.terminal_id !== record.herdr_terminal_id) return { reason: "herdr_wrong_terminal", state: "blocked" };
    return { pane };
  }

  async function pollSeat(registration, paths, cycle) {
    const { team, agent, teamConfig } = registration;
    const seat = seatKey(team, agent);
    const session = readSession(join(installRoot, "run"), team, agent);
    if (session.state !== "present") {
      saveSeat(db, { seat, state: "unaddressable", reason: session.reason ?? "role_session_missing" }, now);
      return;
    }
    const record = session.record;
    if (record.team !== team || record.agent !== agent) {
      saveSeat(db, { seat, state: "blocked", reason: "role_session_identity_mismatch" }, now);
      return;
    }
    if (record.type !== "cursor") {
      saveSeat(db, { seat, state: "blocked", reason: "role_session_type_mismatch" }, now);
      return;
    }
    const locator = record.herdr_locator;
    const optedOut = optedOutOfAgmsgd(installRoot, "cursor", record.project);
    if (optedOut) {
      saveSeat(db, { seat, herdrLocator: locator || null, state: "unaddressable", reason: `delivery_chosen_${optedOut}` }, now);
      return;
    }
    if (record.messaging_blocked) {
      saveSeat(db, { seat, herdrLocator: locator || null, state: "unaddressable", reason: record.messaging_blocked }, now);
      return;
    }
    const registeredProjects = registrationProjects(teamConfig, agent);
    if (registeredProjects.length === 0 || !registeredProjects.some((project) => sameProject(project, record.project))) {
      saveSeat(db, { seat, herdrLocator: locator || null, state: "blocked", reason: "role_session_project_mismatch" }, now);
      return;
    }
    if (!locator || !record.herdr_terminal_id || !record.cursor_conversation_id) {
      saveSeat(db, { seat, herdrLocator: locator || null, state: "unaddressable", reason: "herdr_destination_missing" }, now);
      return;
    }
    const target = parseHerdrLocator(locator);
    if (!target) {
      saveSeat(db, { seat, herdrLocator: locator, state: "blocked", reason: "herdr_locator_invalid" }, now);
      return;
    }
    const block = (reason, state = "blocked") => saveSeat(db, { seat, herdrLocator: locator, state, reason }, now);

    let driver;
    try {
      driver = readDriver(paths.configPath);
    } catch (error) {
      block(`storage_config_unreadable:${error.message}`);
      return;
    }
    if (driver.state !== "ok") { block(driver.reason); return; }
    if (driver.driver !== "sqlite") { block("storage_driver_unsupported"); return; }
    let storePath;
    try {
      storePath = messageStorePath({ storageDir: paths.storageDir, team, teamConfig });
    } catch (error) {
      block(`message_store_path_unreadable:${error.message}`);
      return;
    }
    let store;
    try {
      store = openStore(storePath);
    } catch (error) {
      block(`message_store_unreadable:${error.message}`);
      return;
    }
    let snapshot;
    try {
      snapshot = readSnapshot(store, team, agent, latestNotifiedCursor(db, seat));
    } catch (error) {
      block(`message_store_unreadable:${error.message}`);
      return;
    } finally {
      try { store.close(); } catch { /* keep the read result */ }
    }

    const executable = db.prepare("SELECT herdr_path FROM meta").get()?.herdr_path;
    if (typeof executable !== "string" || !isAbsolute(executable)) { block("herdr_executable_unavailable"); return; }
    // Never run herdr against a path that is not our own live socket.
    const socketCheck = socketAlive(target.socketPath);
    if (socketCheck.reason === "messaging_socket_missing") { block("herdr_socket_missing", "unaddressable"); return; }
    if (socketCheck.state !== "ok") { block(`herdr_socket_unusable:${socketCheck.reason ?? "unknown"}`); return; }
    const listed = await agentList(cycle, executable, target.socketPath);
    if (listed.kind === "cancelled") return;
    if (listed.kind !== "ok") { block(listed.reason); return; }
    const found = matchPane(listed.agents, target, record);
    if (!found.pane) { block(found.reason, found.state); return; }
    const pane = found.pane;

    if (!snapshot.unread || stopped) {
      saveSeat(db, { seat, herdrLocator: locator, state: "addressable" }, now);
      return;
    }
    // A busy pane is retried next poll without a queue row.
    if (BUSY_STATUS.has(pane.agent_status)) {
      saveSeat(db, { seat, herdrLocator: locator, state: "addressable" }, now);
      return;
    }
    if (!SENDABLE_STATUS.has(pane.agent_status)) { block(`herdr_agent_status_unknown:${pane.agent_status.slice(0, 32)}`); return; }

    // An earlier seat's prompt, or a pane swap, may have changed the pane since
    // the cycle's list was taken; decide on the state at send time.
    const fresh = await fetchList(executable, target.socketPath);
    if (fresh.kind === "cancelled") return;
    if (fresh.kind !== "ok") { block(fresh.reason); return; }
    const recheck = matchPane(fresh.agents, target, record);
    if (!recheck.pane) { block(recheck.reason, recheck.state); return; }
    if (BUSY_STATUS.has(recheck.pane.agent_status)) {
      saveSeat(db, { seat, herdrLocator: locator, state: "addressable" }, now);
      return;
    }
    if (!SENDABLE_STATUS.has(recheck.pane.agent_status)) { block(`herdr_agent_status_unknown:${recheck.pane.agent_status.slice(0, 32)}`); return; }

    const nonce = newNonce();
    let id;
    try {
      id = createSendAttempt(db, { seat, herdrLocator: locator, upTo: snapshot.upTo, nonce, expectedOpGen }, now);
    } catch (error) {
      if (error.message !== "daemon_intent_changed") throw error;
      return;
    }
    let outcome;
    try {
      outcome = await run({ executable, socketPath: target.socketPath, args: ["agent", "prompt", target.pane, inboxNudge(nonce)], timeoutMs, signal: pollSignal(), env });
    } catch (error) {
      outcome = { kind: "failed", reason: `send_error:${error?.code ?? error?.message ?? String(error)}` };
    }
    if (outcome.kind === "cancelled") return;
    if (outcome.kind !== "ok") {
      setQueueState(db, id, "expired");
      block(`send_failed:${outcome.reason}`);
      return;
    }
    setQueueState(db, id, "confirmed");
    saveSeat(db, { seat, herdrLocator: locator, state: "addressable" }, now);
  }

  // A team whose roster entry is unusable is skipped alone; its reason is kept
  // as a team-level row (agent "") so `agmsg daemon status` shows it.
  function recordSkippedTeams(skipped) {
    const current = new Map(skipped.map(({ team, reason }) => [team, reason]));
    for (const [team, reason] of current) {
      if (rosterReasons.get(team) === reason) continue;
      log(`channel: cursor roster for team ${team} skipped (${reason})`);
      saveSeat(db, { seat: seatKey(team, ""), state: "unaddressable", reason }, now);
    }
    // Compare against stored rows too: a row written before a restart must go
    // once its team is readable again.
    for (const { seat } of db.prepare("SELECT seat FROM beta_cursor_seat").all()) {
      let parsed;
      try { parsed = JSON.parse(seat); } catch { continue; }
      if (Array.isArray(parsed) && parsed[1] === "" && !current.has(parsed[0])) {
        assertPollActive();
        withImmediateTransaction(db, () => db.prepare("DELETE FROM beta_cursor_seat WHERE seat = ?").run(seat));
      }
    }
    rosterReasons = current;
  }

  async function pollOnce({ signal } = {}) {
    if (stopped) return;
    if (activePoll && !activePollSignal?.aborted) return activePoll;
    activePollSignal = pollSignal() ?? signal;
    const operation = (async () => {
      const roster = listSeats(join(installRoot, "teams"));
      if (roster.state !== "ok") {
        log(`channel: cursor roster unavailable (${roster.reason})`);
        return;
      }
      const paths = storagePaths(installRoot, env);
      const cycle = { lists: new Map() };
      recordSkippedTeams(roster.skipped ?? []);
      const seats = [...roster.seats];
      const registeredKeys = new Set(seats.map(({ team, agent }) => seatKey(team, agent)));
      for (const { team } of roster.skipped ?? []) registeredKeys.add(seatKey(team, ""));
      for (const row of db.prepare("SELECT seat FROM beta_cursor_seat").all()) {
        if (!registeredKeys.has(row.seat)) {
          seatPoller.changeState(row.seat, () => saveSeat(db, { seat: row.seat, state: "unaddressable", reason: "seat_registration_missing" }, now));
        }
      }
      // Resume after an interrupted seat so repeated cycle deadlines cannot
      // starve the tail of a large roster.
      const start = seats.findIndex(seat => seatKey(seat.team, seat.agent) === resumeAfter) + 1;
      const ordered = [...seats.slice(start), ...seats.slice(0, start)];
      for (const seat of ordered) {
        if (stopped || pollSignal()?.aborted || signal?.aborted) break;
        resumeAfter = seatKey(seat.team, seat.agent);
        try {
          await seatPoller.poll(seat, () => pollSeat(seat, paths, cycle));
        } catch (error) {
          if (pollSignal()?.aborted || signal?.aborted) break;
          log(`channel: cursor seat ${seat.team}/${seat.agent} could not be checked (${error.message})`);
        }
      }
    })().finally(() => { if (activePoll === operation) activePoll = null; });
    activePoll = operation;
    return operation;
  }

  return {
    name: 'cursor',
    reportTimeout: seatPoller.reportTimeout,
    pollOnce,
    async stop() {
      stopped = true;
      seatPoller.cancel();
      await activePoll;
    },
  };
}
