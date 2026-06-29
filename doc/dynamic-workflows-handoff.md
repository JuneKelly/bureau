# Dynamic Workflows — Session Handoff

**Purpose:** start a fresh session and continue the dynamic-workflow investigation
without re-deriving everything. This is a working-state snapshot, not a design doc.

**Read these first (in order):**
1. `doc/dynamic-workflows-learnings.md` — the empirical record. **Start with §7
   (N=12 confirming re-run), §8 (viability verdict), and §2.1 / §2.2 (the teardown
   story) — those are the direct context for this session's task.**
2. `doc/dynamic-workflows-feasibility.md` — the original static-read design (context).
3. `omnigent/agent-configs/sybil/skills/dynamic-workflow/SKILL.md` — the **v3** skill
   (committed; the embedded template docstring says `runner (v3)`).

---

## Where things stand

- **Branch:** `dynamic-workflow` (tracking `origin/dynamic-workflow`). Topic branch —
  human-owned. Commit locally; do **not** push or open PRs.
- **Last commit:** `d47439b` — "dynamic-workflow: v3 started-gate confirmed green at
  N=12". Bundles the v3 `SKILL.md` with its validation writeup. Branch is **ahead 1 of
  origin, not pushed** (re-verify with `git status -sb` — don't assume).
- **Server:** local omnigent at `http://127.0.0.1:6767`. Auth is **off** here
  (`GET /v1/me` → 200, `accounts_enabled=False`) — single-user local only.
- **sybil agent_id (last session):** `ag_2d6ad8a72baf417b88317ca6bf724d46` (v3-bound).
- **Roster note:** last session `claude` was on PATH (explorer/builder/drone available)
  but **`codex` was NOT** (reviewer unavailable). **This session's task is a real code
  change and DOES need cross-vendor review** — run the roster preflight first
  (`command -v claude codex || true`); if `codex` is still missing, you cannot run the
  Codex cross-review — say so and pull Junebug in before merging anything.

### What was accomplished last session (N=12 confirmation)
Re-ran the N=12 fan-out probe against the v3 started-gate: **12/12 correct**, each child a
real assistant turn (~17,700 tokens), teardown left **no orphans** (deleted child → 404,
parent `child_sessions` → 0). The v2 first-idle-wins `idle`-race is closed. Full writeup in
learnings §7; verdict in §8. Scratch probe `.sybil/workflows/probe12_v3.py` is on disk
(gitignored); the stale v2 `probe12.py` was deleted.

---

## Start-of-session checks (silent plumbing — only report problems)

- **Server up?** `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:6767/v1/me`
  must be `200`. If down (`000`), STOP and tell Junebug.
- **Roster preflight:** `command -v claude codex || true`. Record the available set.
  `codex` missing ⇒ no cross-vendor review this run (see roster note above).
- **Skill is v3?** (lighter check than last session — this session edits *runner code*,
  not the skill.) If you do touch the skill, remember skill edits are **not hot-reloaded**:
  they need a server+session restart to go live.

---

## THE TASK: let completed child agents PERSIST in the sidebar

**Goal (Junebug's, in her words):** explore the possibility of allowing the child agents to
**persist in the sidebar after they have completed**, instead of vanishing the moment their
turn finishes.

### Why they vanish today (the exact mechanism to undo)
The `dynamic-workflow` skill **deletes every child in a `finally` the moment its result is
captured** (the "B-1b teardown" — see SKILL.md "Why teardown" and learnings §2.1/§2.2). That
teardown is **not hygiene — it is a forced workaround**:

- A parented child created over **raw `POST /v1/sessions`** runs and finishes correctly, but
  the REST create path **never registers a parent-side "work entry."** That entry
  (`register_subagent_work()` in `runner/app.py`) is created **only** on the in-runner
  dispatch path (`runner/tool_dispatch.py`, the path `sys_session_send` drives).
- Without it, when the child finishes the runner tries to deliver its terminal status to the
  parent inbox, hits `missing_work_entry`, and **retries forever** — a runner log storm
  (`subagent_delivery_not_confirmed` / `missing_work_entry`) that contends with live work.
- Deleting the child the instant its result is captured removes the thing the runner keeps
  retrying against. **So persistence and the retry-storm are the same problem:** you cannot
  let children persist until the undeliverable-completion storm is fixed.

This is **Tier 2** in the viability verdict (learnings §8): "persistent nested children,
robust locally — ONE real fix away."

### The two candidate fixes (from learnings §5 rec 1–3)
1. **Register a parent work-entry on REST create** — so REST-spawned parented children can
   deliver terminal status like dispatch-path children do. Children then **nest *and*
   persist *and* deliver**, and teardown becomes optional.
2. **OR mark REST-created children "externally tracked, no parent delivery expected"** so the
   runner **suppresses** forwarding (no delivery attempt → no storm) while the child persists.
3. **Regardless of 1 vs 2: stop the runner retrying an undeliverable terminal status
   indefinitely** — `missing_work_entry` should drop/no-op or back off, not storm. (This is
   the safety net even if persistence is achieved another way.)

### This is a CODE change — delegate it, don't write it
The runner (`runner/app.py`, `runner/tool_dispatch.py`, `sessions.py`) is real product
source. **sybil does not write code.** Route the work:
- **explore** (`explorer`) — map the path before touching anything.
- **implement** (`builder`) — make the change, drive tests/lint/typecheck green, commit
  locally on `dynamic-workflow` (or a `sybil/<topic>/<task_id>` fanout branch).
- **review** (`reviewer`, Codex) — cross-vendor verify the diff against its contract.
  **Requires `codex` on PATH** (see roster note).

### Suggested approach (cheap experiment first, then the build)
1. **Cheapest first probe (no code change): a no-teardown variant.** Copy
   `.sybil/workflows/probe12_v3.py` to a scratch variant that **skips `delete_child` on
   success** (keep teardown on failure), run it at **N≥3** (validate concurrency, never N=1),
   and OBSERVE: (a) do the completed children actually persist/appear in the Subagents panel?
   (b) does the runner log show the `missing_work_entry` storm, and how bad? This scopes the
   real fix and gives a concrete before-picture. **Remember to sweep any persisted children
   afterward** via `DELETE /v1/sessions/{id}` — they won't tear themselves down.
2. **Explore the delivery path** (`explorer`, `purpose: explore`): trace
   `register_subagent_work()` and all its callers; the completion-forwarding + retry loop and
   where `missing_work_entry` is raised; how the Subagents panel / `child_sessions` decides
   what to show (does a non-deleted completed child already render, or is more needed?); and
   which of fix (1) vs (2) is smaller/safer. Ask for a structured report with `file:line`
   anchors and a recommended option.
3. **Decide** fix (1) vs (2) with Junebug at the plan gate.
4. **Implement** (`builder`) behind **cross-review** (`reviewer`), commit locally.
5. **Validate:** re-run the no-teardown N≥3 probe and confirm children **persist in the
   sidebar AND the runner log is clean** (no `missing_work_entry` storm). If anything fails:
   STOP, show the exact failed request + response body + relevant runner log lines.

### Definition of done
Completed child agents remain visible in the sidebar after their turn finishes, with **no
runner retry-storm**, validated at N≥3, diff cross-reviewed by Codex, committed locally on
`dynamic-workflow` (not pushed). Fold the outcome back into learnings (§2.1/§2.2 lose their
"teardown is mandatory" framing; §8 Tier-2 moves from "one fix away" to "done") and SKILL.md
(teardown becomes optional / persistence becomes the documented default for review-style runs).

---

## Verified wire facts (don't re-guess — but re-confirm in the server-up check)

- **Create + seed a child:** `POST /v1/sessions` with body `{agent_id, sub_agent_name,
  parent_session_id, title, initial_items:[<message item>]}`. The message item is
  `{"type":"message","data":{"role":"user","content":[{"type":"input_text","text":"…"}]}}`.
  (The create body is **hidden from `openapi.json`** — no requestBody schema — but is proven
  by repeated successful creates.) `POST /v1/sessions/{id}/events` takes the same message
  body to steer an already-running session.
- **Read results:** `GET /v1/sessions/{id}/items?order=desc&limit=N` is **flat OpenAI-style**:
  `{object,data,first_id,last_id,has_more}`, with `role`/`content` **top-level**; assistant
  text parts are `type:"output_text"`. (The internal history view nests under `data` — a
  different surface. Use the flat one here.)
- **`status` `idle` is OVERLOADED:** it means BOTH "created, seeded turn not dispatched yet"
  AND "turn finished." Completion is NOT `status != "running"` alone — gate on the turn having
  provably run (saw `running`, OR an assistant message exists). `status:"failed"` carries
  `last_task_error`. (This is the v3 started-gate; do not regress it.)
- **A captured-but-inert child** = items are just the seed, **0 assistant messages**,
  `last_total_tokens`/`total_cost_usd`/`host_id` all `None`. That signature = "the turn never
  ran." A genuinely-run child = ≥1 assistant message + non-zero tokens (~17.7k for a trivial
  one-word turn). NB: `host_id` reads `None` in the *post-run* snapshot too (host released) —
  use tokens + assistant message as the "it ran" signal, not `host_id`.
- **Parent id is NOT ambient:** `OMNIGENT_SESSION_ID` is empty in the `sys_os_shell`
  subprocess. Inject `OMNIGENT_PARENT_SESSION_ID=<your conv id from sys_session_get_info>` on
  the run command. Required-or-bail; no heuristic discovery.
- **REST-created children are invisible to `sys_session_*`** (no `parent_session_id` linkage;
  `sys_session_close` can't tear them down). Cleanup is **only** via `DELETE
  /v1/sessions/{id}` — so a no-teardown probe must sweep its own persisted children.
- **Workers have no standalone `agent_id`** — `explorer`/`builder`/`drone`/`reviewer` exist
  only as sub-agents in sybil's spec tree, resolved via `parent_session_id + sub_agent_name`.
- **Re-runs collide:** `(parent, title)` must be unique or `POST /v1/sessions` → **500**
  (`NameAlreadyExistsError`). Use run-scoped titles, e.g. `wf-{runid}-task-{i}`.
- **SSE** `GET /v1/sessions/{id}/stream?idle=true` is a live-tail with **no history replay**
  (`idle` = presence flag, not completion). Poll the snapshot; don't await SSE.
- **Teardown:** `DELETE /v1/sessions/{id}` → `{deleted:true}`. Confirmed working.

---

## Known platform warts (this session's task is to fix #1/#2/#3)
1. **REST-created parented children get no parent work-entry** → can't deliver completion →
   runner retry-storm. `register_subagent_work()` is only called on the in-runner dispatch
   path, never on REST create. **← the headline build target this session.**
2. **The runner retries an undeliverable terminal status indefinitely** (`missing_work_entry`
   should drop/back off, not storm). **← fix alongside #1.**
3. **`status` `idle` is overloaded** (pre-dispatch vs finished) — a distinct
   `created`/`queued` state before first dispatch would let clients drop the started-gate.
   (Nice-to-have; not required for persistence.)
4. **Title collision is a 500, should be 409** (`NameAlreadyExistsError`). Run-scoped titles
   dodge it; lower priority.

---

## Operating reminders for the next session
- **This task IS a code change** — delegate to `builder`, cross-review with `reviewer`
  (Codex). sybil does not write runner code. Docs/skills (prose) are authored directly.
- **Cross-review needs `codex` on PATH** — run the roster preflight; if missing, you can't run
  independent cross-vendor review — pull Junebug in before merging.
- **Validate concurrency at N≥3, never N=1** — the worst failure mode is timing-dependent
  (learnings §2.8).
- **Skill edits need a server+session restart to go live** (not hot-reloaded) — budget for it
  if you touch SKILL.md.
- A no-teardown probe **leaks children** unless you sweep them with `DELETE /v1/sessions/{id}`.
- Commit locally on `dynamic-workflow`; do **not** push, do **not** open PRs. The one merge
  that's yours is a fanout task-branch → topic-branch merge-back.
- Address the operator as **Junebug**.
