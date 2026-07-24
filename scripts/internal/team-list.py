#!/usr/bin/env python3
"""Aggregate every locally known team's config.json into the strict
`agmsg team list --json` ABI (ADR 0007 family addition). See
scripts/team-list.sh's own header comment for the full field contract.

Reads two small input files by path (never a huge argv, since a
pathological team count/project-path could otherwise blow past ARG_MAX):
  --entries <path>   TAB-separated "<name>\t<config_path>" lines, one per
                      locally known team directory (already existence-
                      checked and bounded by the caller).
  --variants <path>  one project-path spelling per line (from
                      agmsg_project_path_variants) — a team is "project"-
                      scoped if ANY agent registration's `project` field
                      exactly matches ANY of these.

Each config.json is read up to --max-config-bytes+1 bytes and rejected
(skipped, with a stderr warning naming the team) if it exceeds that
bound, isn't valid UTF-8 JSON, isn't a JSON object, or contains a
duplicate key at any nesting depth (the same #87/D4-class strict-parsing
discipline this ADR family already applies to server-supplied JSON —
config.json is locally written by our own scripts, but this is a
read-only listing command with no reason to guess at a malformed file's
meaning rather than skip it outright).
"""
import argparse
import json
import sys


def _warn_skip(name, reason):
    print(f"agmsg: team list: skipping '{name}': {reason}", file=sys.stderr)


def _no_duplicate_keys(pairs):
    seen = set()
    out = {}
    for key, value in pairs:
        if key in seen:
            raise ValueError(f"duplicate key '{key}'")
        seen.add(key)
        out[key] = value
    return out


def _strict_loads(raw):
    return json.loads(raw, object_pairs_hook=_no_duplicate_keys)


def _registrations_for(agent_value):
    regs = agent_value.get("registrations")
    if isinstance(regs, list):
        return regs
    # Legacy single-registration shape (type/project directly on the agent
    # object, no "registrations" array) — join.sh normalizes to the array
    # form on write, but an older config on disk may still be in this shape.
    return [{"type": agent_value.get("type"), "project": agent_value.get("project")}]


def _team_row(name, cfg, variants):
    binding = cfg.get("remote_binding")
    if not isinstance(binding, dict):
        binding = {}
    connected_at = binding.get("connected_at")
    disconnected_at = binding.get("disconnected_at")
    if not connected_at:
        binding_state = "none"
    elif disconnected_at:
        binding_state = "disconnected"
    else:
        binding_state = "active"

    team_id = binding.get("remote_team_id") if binding_state != "none" else None
    if not isinstance(team_id, str) or not team_id:
        team_id = None

    scope = "other"
    agents = cfg.get("agents")
    if isinstance(agents, dict):
        for agent_value in agents.values():
            if not isinstance(agent_value, dict):
                continue
            for reg in _registrations_for(agent_value):
                if isinstance(reg, dict) and reg.get("project") in variants:
                    scope = "project"
                    break
            if scope == "project":
                break

    # PLACEHOLDERS pending ADR 0010 (local-first onboarding / roster
    # convergence) — see team-list.sh's header comment for why these three
    # are deliberately coarse/fail-closed rather than a preview of that
    # design's real state machine.
    onboarding_state = "connected" if binding_state in ("active", "disconnected") else "not_connected"
    promote_eligible = False
    blocked_reason = "adr_0010_not_implemented"

    return {
        "name": name,
        "team_id": team_id,
        "scope": scope,
        "binding_state": binding_state,
        "onboarding_state": onboarding_state,
        "promote_eligible": promote_eligible,
        "blocked_reason": blocked_reason,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--entries", required=True)
    parser.add_argument("--variants", required=True)
    parser.add_argument("--scope", required=True, choices=("all", "project"))
    parser.add_argument("--max-config-bytes", required=True, type=int)
    parser.add_argument("--format", required=True, choices=("human", "json"))
    args = parser.parse_args()

    with open(args.variants, encoding="utf-8") as f:
        variants = {line.rstrip("\n") for line in f if line.rstrip("\n")}

    rows = []
    with open(args.entries, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            name, _, cfg_path = line.partition("\t")
            if not cfg_path:
                continue
            try:
                with open(cfg_path, "rb") as cf:
                    raw = cf.read(args.max_config_bytes + 1)
            except OSError as exc:
                _warn_skip(name, f"could not read config ({exc.__class__.__name__})")
                continue
            if len(raw) > args.max_config_bytes:
                _warn_skip(name, "config exceeds the byte limit")
                continue
            try:
                cfg = _strict_loads(raw.decode("utf-8"))
            except Exception as exc:
                _warn_skip(name, f"invalid config ({exc})")
                continue
            if not isinstance(cfg, dict):
                _warn_skip(name, "config is not a JSON object")
                continue
            rows.append(_team_row(name, cfg, variants))

    if args.scope == "project":
        rows = [r for r in rows if r["scope"] == "project"]

    # Canonical sort (name, then team_id — team_id is null-safe via "").
    rows.sort(key=lambda r: (r["name"], r["team_id"] or ""))

    if args.format == "json":
        sys.stdout.write(json.dumps({"schema_version": 1, "teams": rows}, sort_keys=True) + "\n")
    else:
        if not rows:
            print("No teams found.")
        else:
            for r in rows:
                team_id_disp = r["team_id"] or "-"
                print(f"{r['name']}\t{team_id_disp}\t{r['scope']}\t{r['binding_state']}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
