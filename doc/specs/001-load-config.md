# Spec 001 — `load-config`: user-configurable sub-agent models

| | |
|---|---|
| **Status** | Draft (rev 2 — bash+jq, minimal) |
| **Author** | sybil (with Junebug) |
| **Date** | 2026-07-13 |
| **Branch** | `sybil-config-skill` |
| **Affects** | `omnigent/agent-configs/sybil/config.yaml`, new `omnigent/agent-configs/sybil/skills/load-config/` |

> **Rev 2 note.** The resolver was first built in Python (commit `86b7319`) with
> in-script shape validation and an `_meta` advisory block. That was
> over-built. Rev 2 collapses the script to a minimal **bash + jq** resolver:
> discover paths, read present files, deep-merge over defaults, emit. All
> advisory / validation judgment moves to the orchestrator. The Python commit is
> superseded.

## 1. Summary

A runtime config file, resolved by a new `load-config` skill, lets a user
override which **model** each sybil sub-agent (`explorer`, `builder`, `drone`,
`reviewer`) runs on — without editing sybil's prompt or re-deploying the agent.
The orchestrator invokes the skill during its first-turn preflight and applies
the resolved model values via `args.model` at every dispatch.

## 2. Motivation

Today the model per sub-agent is hard-coded in sybil's prompt (the "Model
dispatch table", `config.yaml` ~L93–97). Changing any of it means editing the
agent and re-uploading. A runtime config read at session start — applied through
the existing `args.model` dispatch parameter — is the correct layer for user
control: it changes behavior without touching the agent definition, and composes
with future multi-vendor harnesses that widen viable cross-vendor review pairs.

## 3. Goals

- G1. Let a user set the model for any of the four sub-agents via a config file.
- G2. Two config locations — user-global and per-project — with defined precedence.
- G3. Deterministic built-in defaults so behavior is unchanged when no config exists.
- G4. Reliable first load (preflight) + on-demand reload later in a session.
- G5. Keep the script minimal; push judgment (validation, advisories) to the orchestrator.

## 4. Non-goals

- N1. Configuring anything other than model.
- N2. Retargeting already-running sub-agents (`args.model` binds at session creation).
- N3. Prohibiting intra-vendor review (permitted; see §9).
- N4. In-script shape validation, advisory bookkeeping, or an `_meta` block. The
  script does discovery + merge + emit, nothing more.

## 5. Configuration file

### 5.1 Locations & precedence

1. **Global:** `~/.config/omnigent-sybil/config.json`
2. **Project:** `<repo_root>/.sybil-config.json` (`<repo_root>` via `git
   rev-parse --show-toplevel`; tolerate not being in a git repo)

**Project overrides global.** Resolution is a per-key deep merge of
`defaults ⊕ global ⊕ project`, later layer winning per key. An absent layer
contributes nothing. jq's recursive-merge operator (`*`) provides exactly this.

### 5.2 Schema (v1) & defaults

Model-only. Every field optional; omitted fields inherit from the next lower
layer, ultimately the baked defaults.

The baked defaults live in a plain file shipped with the skill,
`defaults.json` (no embedding, no heredoc — a file jq reads):

```json
{
  "version": 1,
  "agents": {
    "explorer": { "model": "claude-opus-4-8" },
    "builder":  { "model": "claude-opus-4-8" },
    "drone":    { "model": "claude-sonnet-4-6" },
    "reviewer": { "model": null }
  }
}
```

- Model IDs use dash-format — `claude-sonnet-4-6`, not `claude-sonnet-4.6`.
- `reviewer.model: null` (or omitted) → "omit `args.model`, Codex default".
- A user config sets only the keys it wants to change, e.g.
  `{"agents":{"builder":{"model":"claude-sonnet-4-6"}}}`.

### 5.3 Missing config is expected

Absence of both files is a normal, documented outcome: the resolver emits the
baked defaults. This is the legitimate optional-config-with-default case, not a
silent-default violation — absence is semantically meaningful (use defaults).

## 6. Resolver script (minimal)

`omnigent/agent-configs/sybil/skills/load-config/resolve-config.sh`. Behavior:

1. One-line dependency guard: if `jq` is not on PATH, print an actionable
   "install jq" message to stderr and exit non-zero. (The only guard kept.)
2. Resolve the global and project paths (§5.1). Env seams
   `SYBIL_GLOBAL_CONFIG` / `SYBIL_PROJECT_CONFIG` may override paths for testing,
   but default behavior is the real §5.1 discovery.
3. Build the merge list: `defaults.json`, then the global file **if it exists**,
   then the project file **if it exists**. Non-existent files are simply skipped.
4. Deep-merge and emit to stdout:
   `jq -s 'reduce .[] as $x ({}; . * $x)' <files…>`.

That is the whole script (~10–15 lines). No shape validation, no advisories, no
`_meta`.

### 6.1 Output contract

Stdout is the single resolved JSON document — `{version, agents}` only:

```json
{
  "version": 1,
  "agents": {
    "explorer": { "model": "claude-opus-4-8" },
    "builder":  { "model": "claude-sonnet-4-6" },
    "drone":    { "model": "claude-sonnet-4-6" },
    "reviewer": { "model": null }
  }
}
```

### 6.2 Dependency

`jq` is the one hard dependency (confirmed present in the dev environment;
`jq-1.8.1`). Absence fails loudly per §6.1. No Python. Malformed JSON in any
config file is caught by jq itself: jq exits non-zero and prints a parse error —
that **is** the loud failure (no hand-rolled validation needed).

## 7. The `load-config` skill

`omnigent/agent-configs/sybil/skills/load-config/SKILL.md` (+ `resolve-config.sh`
+ `defaults.json`).

Frontmatter matches existing skills (`name` / `description`). The body instructs
the orchestrator to run the resolver, read the resolved JSON into context, apply
the orchestrator-side checks of §8.2, and use each `agents.<name>.model` as
`args.model` on subsequent dispatches. Ships a `.sybil-config.example.json`
sample.

**Why a skill:** packages the script + defaults + instructions as one
controllable unit, and is **re-invokable** mid-session to reload after an edit
(also mitigating loss of the values across context compaction — just re-run it).

## 8. Orchestrator integration

### 8.1 Preflight (first load)

The first-turn preflight (`config.yaml` ~L78–90), which already runs the roster
`command -v claude codex` check, additionally invokes `load-config` in the
**same** first turn. Like the roster check, config loading is silent plumbing:
say nothing on a clean load; surface only what matters per §8.2.

### 8.2 Orchestrator-side judgment (moved out of the script)

The script only merges. The orchestrator, holding the resolved JSON in context,
does the thin judgment:

- **Model-availability validation.** Configured model IDs are checked against
  `sys_list_models` when in doubt; an invalid model/worker combination already
  **fails loud at dispatch**. That dispatch-time failure is the backstop.
- **Same-vendor reviewer warning (soft).** If the resolved config puts
  `reviewer` on the same vendor as an implementer, surface a one-line advisory
  once — non-blocking. Cross-vendor stays the default (see §9); collapsing it is
  the user's explicit, acknowledged choice.
- **Unexpected-key sanity.** Glance at the resolved `agents` for keys other than
  the four known agents / `model`; a typo'd key (e.g. `modle`) silently no-ops
  in the merge, so note it rather than let the user believe an override took.

The Model dispatch table in `config.yaml` is reframed from hard-coded values to
"the resolved config's `agents.<name>.model`, defaulting to the table below when
unset". Table values remain the documented defaults (identical to
`defaults.json`).

### 8.3 Reload semantics

`args.model` binds at **session creation**. Re-invoking `load-config` mid-run
changes only *future* dispatches; already-running sub-agents keep the model they
booted with. The skill states this so a reload isn't mistaken for live
retargeting.

## 9. Invariants & safety

- **Cross-vendor review is the default, not a mandate.** `defaults.json` keeps
  `reviewer` at `null` (Codex, off-vendor from the Claude implementers),
  preserving structural independence out of the box. A user *may* override
  `reviewer.model` (including same-vendor); they accept that risk, and the
  orchestrator surfaces the §8.2 soft warning.
- **No silent wrong answer.** Malformed config → jq exits non-zero (§6.2).
  Wrong-shape config (e.g. `agents: null`) yields output that fails at the
  orchestrator when it reads the models — a loud failure at that layer, not a
  silent default. Missing config → documented defaults (§5.3).
- **Accepted minor footgun.** A typo'd per-agent key silently no-ops in the
  merge; mitigated (not prevented) by the §8.2 unexpected-key glance. This is the
  deliberate price of a minimal script.

## 10. Failure modes

| Condition | Behavior |
|---|---|
| No config files | Resolved = baked defaults; silent. |
| Malformed JSON | jq exits non-zero with a parse error; orchestrator reports and falls back to defaults for the run. |
| `jq` missing | Loud, actionable "install jq" message; non-zero exit. |
| Unknown agent / top-level key | Merged through harmlessly; orchestrator's §8.2 glance may note it. |
| Typo'd per-agent key (`modle`) | Silently no-ops (default used); §8.2 glance may note it. |
| Wrong-shape value (`agents: null`) | Produces malformed resolved output; fails loud at the orchestrator when reading models. |
| Configured model ID invalid for worker | Loud failure at dispatch (`sys_list_models` / dispatch error). |
| `reviewer` collapsed to implementer vendor | Dispatch proceeds; orchestrator surfaces a one-line soft warning. |

## 11. Open questions

- Q1. ~~Merge dependency (jq vs python3)~~ — **resolved: jq.**
- Q2. ~~Distinguish global found-but-empty vs not-found~~ — **dropped** (no
  `_meta`; not worth tracking).
- Q3. Config filename: `.sybil-config.json` at root (chosen) vs `.sybil/…`.
  `**/.sybil` is gitignored, so a `.sybil/`-nested config would be untracked by
  default — `.sybil-config.json` at root is intentionally trackable.

## 12. Out of scope / future

- Non-model config (reasoning effort, cost budgets, roster composition).
- Per-task / per-dispatch overrides in config.
- A config-validation subcommand / schema file for editor tooling.
