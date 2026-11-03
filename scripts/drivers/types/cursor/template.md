<!-- Cursor CLI overlay. -->
<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
  5. **REQUIRED — Do NOT skip this step.** Choose `turn` or `off` delivery (empty input means `turn`), then run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`. Cursor CLI has no monitor equivalent. When Cursor runs in a herdr pane, `agmsgd` is also available: run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery agmsgd --type __AGENT_TYPE__ --project "$(pwd)"` and agmsgd types a one-line notice into this pane when messages arrive.
<!-- /agmsg:slot delivery -->
<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.
For `mode turn|off`, run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`; reject `monitor` and `both`.
For `mode agmsgd`, run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery agmsgd --type __AGENT_TYPE__ --project "$(pwd)"`; it needs Cursor running in a herdr pane, and the session starts no inject watcher.
When a prompt reads `[agmsg:<nonce>] New messages are waiting. Check your agmsg inbox.`, it came from agmsgd: run `~/.agents/skills/__SKILL_NAME__/scripts/inbox.sh $TEAM $AGENT` for each of your TEAMS and read the messages there.
<!-- /agmsg:slot mode -->
