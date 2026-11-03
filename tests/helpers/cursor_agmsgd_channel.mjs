// Drives the cursor agmsgd channel against a stub herdr, a real Unix socket and a
// real sqlite team store. Run by tests/test_cursor_agmsgd.bats as
// `node cursor_agmsgd_channel.mjs <scenario>`; a failed assertion exits non-zero.
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, chmodSync, rmSync } from 'node:fs';
import { createServer } from 'node:net';
import { DatabaseSync } from 'node:sqlite';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const daemon = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../scripts/daemon');
const { openInstallDb } = await import(`${daemon}/db.mjs`);
const { createCursorQueueChannel } = await import(`${daemon}/channels/cursor-queue.mjs`);
const { ensureCursorChannelSchema } = await import(`${daemon}/channels/cursor-queue-store.mjs`);

const scenario = process.argv[2];
const RECORD_TERMINAL = 'term_1';
const AMBIENT_SOCKET = '/ambient/wrong.sock';

// The socket sits directly under the temp dir because sun_path is short on macOS.
const root = mkdtempSync(path.join(os.tmpdir(), 'cq-'));
const project = path.join(root, 'proj');
mkdirSync(project);
const sock = path.join(root, 'h.sock');
const server = createServer();
await new Promise((r) => server.listen(sock, r));
mkdirSync(path.join(root, 'run'));
mkdirSync(path.join(root, 'teams/t'), { recursive: true });
mkdirSync(path.join(root, 'db'));
writeFileSync(path.join(root, 'teams/t/config.json'), JSON.stringify({ agents: { a: { registrations: [{ type: 'cursor', project }] } } }));
writeFileSync(
  path.join(root, 'run/role-session.t__a'),
  `team=t\nagent=a\ntype=cursor\nproject=${project}\nherdr_locator=${sock}:wN5:p1\nherdr_terminal_id=${RECORD_TERMINAL}\ncursor_conversation_id=c1\n`,
);

const store = new DatabaseSync(path.join(root, 'db/messages.db'));
store.exec(`CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT, id TEXT, team TEXT, from_agent TEXT, to_agent TEXT, body TEXT, msg_id TEXT, agent TEXT, at TEXT, legacy_id INTEGER);
CREATE TABLE messages (id INTEGER PRIMARY KEY, team TEXT, to_agent TEXT, read_at TEXT, created_at TEXT, body TEXT);
CREATE TABLE read_cursors (team TEXT, agent TEXT, local_position INTEGER, PRIMARY KEY(team, agent));`);
const send = (id) => store.prepare("INSERT INTO events (type,id,team,from_agent,to_agent,body,at) VALUES ('message_sent',?,'t','x','a','hi','now')").run(id);
const dump = () => JSON.stringify(['events', 'messages', 'read_cursors'].map((t) => store.prepare(`SELECT * FROM ${t}`).all()));

const stubDir = path.join(root, 'stub');
mkdirSync(stubDir);
const calls = path.join(stubDir, 'calls.log');
const listFile = path.join(stubDir, 'list.json');
const stub = path.join(stubDir, 'herdr');
writeFileSync(stub, `#!/bin/sh
if [ "$1" = agent ] && [ "$2" = list ]; then
  out=$(cat "${listFile}")
  if [ -f "${stubDir}/work_after_prompt" ] && [ "$(wc -l < "${calls}")" -gt "$(cat "${stubDir}/work_after_prompt")" ]; then
    out=$(printf '%s' "$out" | sed 's/"agent_status":"idle"/"agent_status":"working"/')
  fi
  printf '%s' "$out"; exit 0
fi
if [ "$1" = agent ] && [ "$2" = prompt ]; then printf 'PROMPT|%s|%s|%s\\n' "$3" "$4" "$HERDR_SOCKET_PATH" >> "${calls}"; exit 0; fi
exit 9
`);
chmodSync(stub, 0o755);
const setList = (status, terminal = RECORD_TERMINAL) => writeFileSync(listFile, JSON.stringify({
  id: 'cli:agent:list',
  result: {
    agents: [
      { agent: 'cursor', agent_status: status, cwd: project, pane_id: 'wN5:p1', terminal_id: terminal, tab_id: 'wN5:t1', workspace_id: 'wN5' },
      { agent: 'claude', agent_status: 'working', cwd: '/x', pane_id: 'wN5:p2', terminal_id: 'term_2' },
    ],
    type: 'agent_list',
  },
}));
const prompts = () => (existsSync(calls) ? readFileSync(calls, 'utf8').trim().split('\n').filter(Boolean) : []);

const db = openInstallDb(path.join(root, 'run/install.db'));
ensureCursorChannelSchema(db);
db.exec("UPDATE daemon_intent SET desired='on', op_gen=1");
db.prepare('UPDATE meta SET herdr_path=?').run(stub);
const channel = createCursorQueueChannel({
  db,
  installRoot: root,
  expectedOpGen: 1,
  env: { ...process.env, HERDR_SOCKET_PATH: AMBIENT_SOCKET, HERDR_PANE_ID: 'wZ:p9', AGMSG_STORAGE_PATH: path.join(root, 'db'), AGMSG_CONFIG: path.join(root, 'none.json') },
  log: () => {},
});
const seat = () => ({ ...db.prepare('SELECT state, reason FROM beta_cursor_seat').get() });

try {
  if (scenario === 'nudge') {
    send('m1');

    setList('working');
    await channel.pollOnce();
    assert.equal(prompts().length, 0, 'a working pane must not be nudged');

    setList('idle');
    const before = dump();
    await channel.pollOnce();
    const sent = prompts();
    assert.equal(sent.length, 1, 'an idle pane is nudged exactly once');
    assert.match(sent[0], /^PROMPT\|wN5:p1\|\[agmsg:[0-9a-f-]{36}\] /);
    assert.equal(sent[0].split('|')[3], sock, 'herdr must receive the record socket, not the daemon environment one');
    assert.notEqual(sock, AMBIENT_SOCKET);
    assert.equal(dump(), before, 'sending a nudge must not change message data or the read cursor');

    for (let i = 0; i < 3; i++) await channel.pollOnce();
    assert.equal(prompts().length, 1, 'the same notice must not be resent on later polls');

    // Two seats (teams t and t2) share one pane. The first nudge makes the pane
    // busy, so the second seat's fresh list before its own prompt must see that.
    mkdirSync(path.join(root, 'teams/t2'));
    writeFileSync(path.join(root, 'teams/t2/config.json'), JSON.stringify({ agents: { a: { registrations: [{ type: 'cursor', project }] } } }));
    const record = readFileSync(path.join(root, 'run/role-session.t__a'), 'utf8');
    writeFileSync(path.join(root, 'run/role-session.t2__a'), record.replace('team=t\n', 'team=t2\n'));
    setList('idle');
    writeFileSync(path.join(stubDir, 'work_after_prompt'), String(prompts().length));
    const base = prompts().length;
    const sendTo = (team, id) => store.prepare("INSERT INTO events (type,id,team,from_agent,to_agent,body,at) VALUES ('message_sent',?,?,'x','a','hi','now')").run(id, team);
    sendTo('t', 'm2');
    sendTo('t2', 'm1');
    await channel.pollOnce();
    assert.equal(prompts().length - base, 1, 'a second seat on a pane that turned busy after the first nudge must not be nudged');
    console.log('nudge ok');
  } else if (scenario === 'wrong-terminal') {
    send('m1');
    setList('idle', 'term_OTHER');
    await channel.pollOnce();
    assert.equal(prompts().length, 0, 'a pane whose terminal_id differs from the record must not be nudged');
    assert.deepEqual(seat(), { state: 'blocked', reason: 'herdr_wrong_terminal' });
    console.log('wrong-terminal ok');
  } else {
    throw new Error(`unknown scenario: ${scenario}`);
  }
} finally {
  await channel.stop();
  db.close();
  store.close();
  server.close();
  rmSync(root, { recursive: true, force: true });
}
