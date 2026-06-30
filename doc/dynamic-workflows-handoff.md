# Dynamic Workflows — Session Handoff

**Purpose:** entry point for a fresh session. The **persistence test is DONE and green**
(Session 3): a real N=5 `explorer` fan-out ran with persistence on against the Fix-4 server
and hit all four success signals. The **v5** skill shipped (two new client-side lifecycle
fixes), and the learnings doc is folded in. This file is a working-state snapshot + the next
goal, not a design doc.

**Read these first (in order):**
1. `doc/dynamic-workflows-learnings.md` — the empirical record. **§9 (Session 3) is the
   current state.** §2.9 (the `idle` **settle-race**) and §2.10 (empty-`str()` transport
   errors) are the two findings the v5 skill fixes. §8 (viability tiers) — **Tier-2
   persistence is now DONE**; the remaining Tier-2 gap is delivery-only. §2.1/§2.2 are
   reframed (teardown optional; persistence is the default since Fix 4).
2. This file's **"TL;DR"** and **"Next session"**.
3. `doc/dynamic-workflows-feasibility.md` — original static-read design (background).

---

## TL;DR — what's done, what's next

- ✅ **Persistence test DONE & green (Session 3).** Real N=5 `explorer` fan-out authored
  from the template, `TEARDOWN = False`, against the Fix-4 server. All four signals: children
  **persist** (`child_sessions` = 5, none deleted), **no runner storm** (0
  `missing_work_entry` / `subagent_delivery_not_confirmed` / `missing_parent_inbox` / `503`),
  **genuine-run** (~30.6–31.5k tokens/child, 1 assistant msg each), **correct** 5-section
  synthesis returned to the orchestrator. Validated at N=5 (≥3, per the §2.8 rule).
- ✅ **v5 skill shipped.** Two new *client-side*lifecycle defects found while running the
  real fan-out and fixed in `wait_and_read`:
  - **`idle` settle-race (§2.9):** `status` flips to `idle` a few seconds *before* the
    assistant message + tokens commit to `/items`. The v4 "saw `running` → done" gate
    returned `""` in that window. **Fix:** completion signal is now **assistant-text
    present**, not the status flip — keep polling through the settle window.
  - **empty-`str()` transport errors (§2.10):** a 30s poll timeout under cold-boot load
    raised a bare `httpx.ReadError('')` that failed a task with a *blank* message. **Fix:**
    60s client timeout + treat `httpx.HTTPError` during polling as transient (keep polling);
    real server errors are `WireError` and still fail loud.
  - Template bumped **v4 → v5**; compiles clean; Procedure + warts sections updated.
- ✅ **Learnings folded in.** Added §2.9, §2.10, §9; reframed §2.1/§2.2 (teardown optional);
  moved §8 Tier-2 from "one fix away" → **DONE (persistence verified N=5)**.
- 🎯 **Next session — two candidate goals (pick one), detailed below:**
  **(A)** *Concurrency-ceiling probe* (skill `dynamic-workflow`, no code) — push toward ~16
  concurrent / hundreds total to exercise host load and the still-absent per-run cap.
  **(B)** *Tier-2 delivery build* (runner **code** → `builder` + Codex `reviewer`) — register
  a parent work-entry on REST create so children **deliver** terminal status, not just persist.

---

## Next session — pick one

### Goal A — concurrency-ceiling probe (skill only, no code)
Push the proven Tier-1 mechanism toward its ceiling to flush the *next* lifecycle pack
(host-load / caps), the way Session 2 (N=12) and Session 3 (N=5 persistence) each flushed a
pack.
- **Use the `dynamic-workflow` skill (now v5).** Author a `workflow.py` from the v5 template
  with real `explorer` tasks; bump `MAX_CONCURRENCY` toward ~16 and total tasks toward the
  hundreds (you are the governor — **no per-run cap exists**).
- **Watch for:** host CPU/RAM pressure and cold-boot stalls (the 60s client timeout + the
  v5 transient-error tolerance should absorb transport noise — confirm they do at scale);
  whether anything *does* bound the fan-out (expected: nothing — that's the open per-run-cap
  gap, feasibility §4/§6 Q3); and whether the settle-race window widens under load.
- **Persistence on or off:** for a hundreds-of-children probe, consider `TEARDOWN = True`
  to keep the tree clean, OR sweep manually afterward (`DELETE /v1/sessions/{id}` per child).

### Goal B — Tier-2 delivery build (runner code → builder + reviewer)
Close the one remaining Tier-2 gap so children **deliver** (not just persist). This is a
**runner code change** — sybil does NOT write it; route to `builder` + Codex `reviewer`.
- **The gap:** REST-created parented children get no parent **work-entry**
  (`register_subagent_work()` is only called on the in-runner dispatch path), so terminal
  status can't be delivered to the parent inbox (learnings §2.1, recommendation 1). The
  program reads items directly instead — which works, so this is an enhancement, not a
  blocker.
- **Acceptance sketch for the builder:** register a work-entry on the REST create path (or
  mark such children "externally tracked, no parent delivery"); add/adjust a test; keep
  Fix 4's 204-ack behavior intact. Cross-review with Codex before merge-back.
- Also worth filing as smaller code fixes (learnings §5): emit a distinct `created`/`queued`
  pre-dispatch state (kills the started-gate workaround); commit the assistant message
  atomically with the status flip (kills the §2.9 settle-race gate); return a typed `409` on
  `(parent, title)` collision instead of a 500.

---

## Two repos (this work spans both)

- **Bureau — skill/docs/learnings:** `/Users/junek/bureau`. Branch **`dynamic-workflow`**
  (tracks `origin/dynamic-workflow`). **This session's changes (committed locally, not
  pushed):** `omnigent/agent-configs/sybil/skills/dynamic-workflow/SKILL.md` → **v5**, plus
  `doc/dynamic-workflows-learnings.md` (§2.9/§2.10/§9 + reframes) and this handoff. See
  `git log` for the commit.
- **Fork — runner code:** `/Users/junek/workspace/omnigent`. `origin = JuneKelly/omnigent`,
  `upstream = omnigent-ai/omnigent`. Branch **`sybil/dynamic-workflows`** (off clean `main`).
  Holds Fix 4 + items A/B from prior sessions (`3591e95a`, `7ec56330`, `b376ccdd`).
  **Unchanged this session** — Goal B is the next thing that would touch it. Local-only.

Note: reference symbols, not line numbers — fork anchors have shifted multiple times.
`sys_os_read`/`sys_os_edit` are scoped to the **bureau** root; read fork files via
`sys_os_shell` (sed/grep/git). The scratch run artifact `.sybil/workflows/persistence-test.py`
is **git-ignored** (not the canonical source — the skill template is).

---

## Verified wire facts (durable — re-confirm in the server-up check, don't re-derive)

- **Base URL is not fixed.** This session's server was `http://127.0.0.1:54533`, discovered
  from `$RUNNER_SERVER_URL` in the `sys_os_shell` env (NOT the old hardcoded `6767`). The
  v5 template reads `OMNIGENT_BASE_URL || RUNNER_SERVER_URL || 127.0.0.1:6767`; sybil passes
  `OMNIGENT_BASE_URL` explicitly on the run command to be safe.
- **`httpx` is not preinstalled.** Run the program with `uv run --with httpx python …`
  (ephemeral dep, no global install). Plain `python3` lacks `httpx`.
- **Create + seed a child:** `POST /v1/sessions` with `{agent_id, sub_agent_name,
  parent_session_id, title, initial_items:[<message item>]}`. Message item:
  `{"type":"message","data":{"role":"user","content":[{"type":"input_text","text":"…"}]}}`.
  (Create body is hidden from `openapi.json` but proven by repeated successful creates.)
  `POST /v1/sessions/{id}/events` takes the same body to steer a running session.
- **Read results:** `GET /v1/sessions/{id}/items?order=desc&limit=N` is flat OpenAI-style:
  `{object,data,first_id,last_id,has_more}`, `role`/`content` top-level; assistant text
  parts are `type:"output_text"`.
- **Persistence check:** `GET /v1/sessions/{parent}/child_sessions` lists children by
  `(kind==\"sub_agent\", parent_conversation_id)` with **no deleted/status filter** — a
  non-deleted completed child still shows here (and in the Subagents panel). (After a
  `DELETE`, the child 404s and drops off this list.)
- **`status` `idle` is OVERLOADED TWICE.** It means BOTH "created, seeded turn not dispatched
  yet" (leading edge, §2.8) AND "turn finished" — and worse, it flips to `idle` a few seconds
  **before** the assistant message + token accounting commit to `/items` (the §2.9
  **settle-race**, trailing edge). **Completion = assistant text PRESENT**, never a status
  read. Keep polling through both windows; fail loud at the deadline. This is the v5 gate —
  do not regress it to "saw running == done" (the v4 bug) or "first idle == done" (v2 bug).
- **Transport errors during polling are transient.** A bare `httpx.ReadError('')` (empty
  `str()`!) appears under cold-boot load; the v5 waiter swallows `httpx.HTTPError` and keeps
  polling. Real server errors are `WireError` (not `httpx.HTTPError`) and still fail loud.
  Client timeout is 60s.
- **Run vs inert child:** genuinely-run = ≥1 assistant message + non-zero tokens (~31k for a
  multi-paragraph turn this session; ~17.7k for a one-word turn). Inert = seed only, 0
  assistant messages, tokens/cost `None`. NB `host_id` is `None` in the post-run snapshot too
  (host released) — use tokens + assistant message as the "it ran" signal.
- **Parent id is NOT ambient:** `OMNIGENT_SESSION_ID` is empty in the `sys_os_shell`
  subprocess. Inject `OMNIGENT_PARENT_SESSION_ID=<your conv id from sys_session_get_info>`
  on the run command. Required-or-bail.
- **REST-created children are invisible to `sys_session_*`** (sybil's MCP tools — no linkage
  there), but ARE visible via the REST `child_sessions` query above. Manual cleanup only via
`DELETE /v1/sessions/{id}`.
- **Workers have no standalone `agent_id`** — explorer/builder/drone/reviewer exist only as
  sub-agents in sybil's spec tree, resolved via `parent_session_id + sub_agent_name`.
- **Re-runs collide:** `(parent, title)` must be unique or `POST /v1/sessions` → 500
  (`NameAlreadyExistsError`). Use run-scoped titles, e.g. `wf-{runid}-task-{i}`.
- **SSE** `GET /v1/sessions/{id}/stream?idle=true` is a live-tail with no history replay
  (`idle` = presence flag, not completion). Poll the snapshot; don't await SSE.
- **Teardown:** `DELETE /v1/sessions/{id}` → `{deleted:true}`.

---

## Platform warts — current status

1. ✅ **REST-created parented children get no parent work-entry → no inbox delivery.** Storm
   **fixed by Fix 4** (204-ack instead of 503-storm), so children persist safely. Delivery
   itself still doesn't happen — the program reads child items directly. Registering a
   work-entry on REST create is **Goal B** (the remaining Tier-2 build).
2. ✅ **Runner retried an undeliverable terminal status indefinitely.** Fixed (Fix 4).
3. ⏳ **`status` `idle` overloaded — TWICE** (pre-dispatch §2.8 *and* the §2.9 settle-race
   before items commit). The v5 "assistant-text present" gate handles both; a distinct
   `created`/`queued` state + atomic message/status commit would let clients drop the gate.
4. ⏳ **Per-request transport timeout must absorb cold-boot load** (§2.10). Client-side
   lesson, fixed in v5 (60s + transient tolerance); no server change needed.
5. ⏳ **Title collision is a 500, should be 409** (`NameAlreadyExistsError`). Run-scoped
   titles dodge it; low priority.
6. ⏳ **No per-run cap** on programmatic fan-out (feasibility §4/§6 Q3). Unexercised so far;
   Goal A's concurrency probe is where it would bite.

---

## Operating reminders for the next session

- **Address the operator as Junebug.**
- **Roster preflight first:** `command -v claude codex || true`. Full roster incl. Codex
  `reviewer` expected.
- **The server is patched and live (Fix 4 in).** Don't fixate on a hardcoded port; the proof
  the server is live is that your `sys_*` tools answer. Use `$RUNNER_SERVER_URL` for the base
  URL (this session it was `54533`). If a worker ever fails to *boot* (e.g.
  `ModuleNotFoundError`), the running server may be stale from a mid-flight reinstall — a
  fresh server+session clears it.
- **sybil does not write runner/source code** — any code/test change (Goal B, the §5 fixes)
  → `builder`/`drone` + Codex `reviewer`. Docs/skills (prose) are authored directly by sybil.
- **The `workflow.py` orchestration program IS sybil's to author directly** — it's the
  skill's defining artifact (orchestration plumbing), not product source. The two v5 fixes
  were authored this way.
- **Validate fan-out at N≥3, never N=1** (learnings §2.8).
- **Commit locally only** — bureau `dynamic-workflow`, fork `sybil/dynamic-workflows`. No
  push, no PRs. The one merge that's yours is a fanout task→topic merge-back.

## Suggested skills for the next session

- **`dynamic-workflow` (v5)** — for Goal A; author a real `workflow.py` from the v5 template
  and push concurrency toward the ceiling.
- **`sybil:fanout` + `sybil:cross-review`** — for Goal B; the runner work-entry change is a
  code task for `builder` with a Codex `reviewer` round.
- **`learning-store` / `learning-summarise`** — to fold the next probe's outcome into
  `doc/dynamic-workflows-learnings.md` (a Session-4 section).
