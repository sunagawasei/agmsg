#!/usr/bin/env bash
# codex delivery plug.
#
# codex keeps the default JSON event-hooks apply (agmsg_delivery_apply); it only
# adds enable/disable side effects: install the monitor shim on enable, stop the
# bridge on disable. Sourced into delivery.sh's context, so SKILL_DIR,
# agmsg_resolve_node, CODEX_MONITOR_DOC_URL and stop_codex_bridge are in scope.
# Args (both hooks): on_enable <mode> <type> <project>; on_disable <type> <project>.

agmsg_delivery_on_enable() {
  if AGMSG_CODEX_SHIM_INSTALL_QUIET=1 "$SKILL_DIR/scripts/drivers/types/codex/codex-shim-install.sh" install; then
    echo "Codex monitor shim installed at ~/.agents/bin/codex."
    case ":$PATH:" in
      *":$HOME/.agents/bin:"*)
        echo "Future Codex sessions: launch with codex. In monitor-mode projects, the agmsg shim routes interactive Codex sessions through the bridge."
        ;;
      *)
        # Loud, unambiguous: this is the #1 reason monitor silently does nothing.
        echo "WARNING: ~/.agents/bin is NOT on your PATH, so 'codex' still launches the real"
        echo "  binary and the monitor bridge will NOT engage. Add this line, restart your shell,"
        echo "  then launch with codex:"
        echo "    export PATH=\"\$HOME/.agents/bin:\$PATH\""
        ;;
    esac
  else
    echo "Codex monitor mode is enabled, but the codex shim was not installed."
    echo "Future Codex sessions: launch with $SKILL_DIR/scripts/drivers/types/codex/codex-monitor.sh, or resolve the shim install issue above."
  fi
  # Node preflight: the bridge (codex-bridge.js) is a Node program, so without
  # Node it silently never starts — flag it at enable time. Resolve via the same
  # path the runtime uses (lib/node.sh). AGMSG_NODE / AGMSG_CODEX_NODE override.
  local codex_node
  codex_node="$(agmsg_resolve_node)"
  if ! command -v "$codex_node" >/dev/null 2>&1 && [ ! -x "$codex_node" ]; then
    echo "WARNING: Node.js ('$codex_node') was not found. The Codex bridge needs Node —"
    echo "  monitor delivery will NOT start until Node is installed (or set AGMSG_NODE)."
  fi
  echo "Restart your Codex session (quit and relaunch \`codex\`), then send your first"
  echo "  message — the bridge starts on your first turn, not the moment Codex opens."
  echo "  Already-running sessions stay unmonitored until they restart."
  echo "For more info: $CODEX_MONITOR_DOC_URL"
}

agmsg_delivery_on_disable() {
  local project="$2"
  local stopped
  stopped=$(stop_codex_bridge "$project")
  if [ "${stopped:-0}" -gt 0 ]; then
    echo "Stopped $stopped Codex bridge process(es) for this project and cleaned their run files."
  fi
  echo "Note: the codex shim (~/.agents/bin/codex) is shared across projects, so it was left in place."
  echo "  If no other project uses monitor mode, remove it and restore your PATH:"
  echo "    $SKILL_DIR/scripts/drivers/types/codex/codex-shim-install.sh remove"
  echo "    # then drop ~/.agents/bin from PATH if you added it for monitor"
}
