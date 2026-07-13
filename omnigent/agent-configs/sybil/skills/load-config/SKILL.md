---
name: load-config
description: Resolve sybil's runtime config (per-agent model overrides) from the project and global config files, merged over baked-in defaults, and load the resolved values into context. Run at the first-turn preflight and re-invoke on demand to reload after a config edit.
---

# load-config — runtime model overrides

Lets a user retarget which model each sub-agent (`explorer`, `builder`,
`drone`, `reviewer`) runs on, without editing sybil's prompt or re-deploying the
agent. The resolver script does discovery + merge + emit ONLY; all judgment
(availability, advisories) lives here, with the orchestrator. (Design rationale:
`doc/specs/001-load-config.md`.)

## When to run

- **First-turn preflight** — in the SAME turn as the roster `command -v` check.
- **On demand** — to RELOAD after the user edits a config file mid-session.

## Procedure

1. Run the resolver:
   `sys_os_shell("bash omnigent/agent-configs/sybil/skills/load-config/resolve-config.sh")`
2. Read the resolved JSON from **stdout**. Shape:
   `{ "version": 1, "agents": { "explorer": {"model": …}, "builder": {"model": …}, "drone": {"model": …}, "reviewer": {"model": …} } }`.
   A **non-zero exit** means jq is missing (an install-jq message) or a config
   file is malformed (jq's parse error). Surface the error to the user and fall
   back to the built-in defaults for this run — do not proceed on a broken read.
3. Apply the orchestrator-side checks below.
4. On every subsequent dispatch, pass `agents.<name>.model` as `args.model`.
   A **`null`** model means OMIT `args.model` (use the harness default) — this
   is the norm for `reviewer` (Codex).

## Orchestrator-side checks (the script does none of these)

- **Availability.** If a configured model looks unfamiliar, confirm the target
  worker can run it via `sys_list_models` before dispatching. An invalid
  model/worker pairing fails loud at dispatch regardless — read the error and
  correct rather than retry blindly.
- **Same-vendor reviewer (soft).** If `reviewer`'s resolved model shares a
  vendor with an implementer's (e.g. both Claude), surface ONE non-blocking line
  so the user knows their config has collapsed cross-vendor review. Never block
  — intra-vendor review is allowed; the user owns that risk.
- **Unexpected keys.** If `agents` contains a key that isn't one of the four
  agents, or an agent maps to something other than `{ "model": … }`, note it: a
  typo like `"modle"` silently no-ops in the merge, so tell the user rather than
  let them believe an override took effect.

## Reload semantics

`args.model` binds at session **creation**. Re-running this skill changes only
**future** dispatches; sub-agents already running keep the model they booted
with. A reload is not live retargeting.

## Config locations (reference)

- **Global:** `~/.config/omnigent-sybil/config.json`
- **Project:** `<repo_root>/.sybil-config.json`
- Project overrides global per key; both merge over the baked defaults in
  `defaults.json`. Missing config is normal → built-in defaults. A user sets
  only the keys they want to change — see `.sybil-config.example.json` in this
  directory for the shape.
