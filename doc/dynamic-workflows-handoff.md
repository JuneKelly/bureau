# Dynamic Workflows — Session Handoff

**Purpose:** start a fresh session and **test the dynamic-workflow persistence path
with a real fan-out**. Items A and B are done and committed; the runner is patched
and live. This is a working-state snapshot + the next-session goal, not a design doc.

**Read these first (in order):**
1. `doc/dynamic-workflows-learnings.md` — the empirical record. §2.1/§2.2 (the
   teardown/storm story), §2.8 + §7 (the N=12 `idle`-overload started-gate race and
   its confirming re-run), §8 (viability tiers). NOTE: those sections still frame
   teardown as *mandatory* and Tier-2 as *"one fix away"* — that framing is now stale
   (see below); folding it in is a next-session task, gated on the persistence test.
2. This file's **"TL;DR"** and **"Next session"**.
3. `doc/dynamic-workflows-feasibility.md` — original static-read design (background).

---

## TL;DR — what's done, what's next

- ✅ **Runner storm fix ("Fix 4") — DONE, cross-reviewed, committed.** Fork
  `sybil/dynamic-workflows`: `3591e95a`, `7ec56330`. The runner now
  **204-acknowledges** a non-deliverable sub-agent terminal status instead of
  503-storming.
- ✅ **Item A — de-vacuous leak test — DONE, cross-reviewed clean (Codex, all
  criteria PASS), committed.** Fork `sybil/dynamic-workflows`: `b376ccdd`. Renamed to
  `test_delete_session_drops_sub_agent_name_mapping`; asserts the child id is **absent**
  from `_session_sub_agent_names` after delete (the assertion that actually guards the
  leak-fix `.pop` in `delete_session`). Test-only; pass → (pop removed) fail → (pop
  restored) pass.
- ✅ **Item B — skill persistence default — DONE, committed.** Bureau
  `dynamic-workflow`: `30ec5e9`. `dynamic-workflow/SKILL.md` now **persists children by
  default** (`TEARDOWN = False`); teardown is an opt-in for throwaway runs. Template
  bumped v3 → v4; the v3 started-gate is untouched.
- ✅ **Server: running patched (Fix 4 live)**, per Junebug — so persistence is safe to
  exercise. (Skill edits aren't hot-reloaded; a server+session restart picks up the v4
  skill. Release-coordination is Junebug's concern, deliberately not baked into the skill.)
- 🎯 **Next session goal: test the persistence path with a REAL dynamic-workflow
  fan-out** (not the one-word toy probe). See "Next session" below.

---

## Next session — the test to run

Goal: prove the v4 `dynamic-workflow` skill works end to end with **persistence on**
(`TEARDOWN = False`) for a real, substantive fan-out, against the patched server.

- **Use the `dynamic-workflow` skill.** Author a `workflow.py` from the v4 template
  with real worker tasks (e.g. a handful of genuine `explorer` research/audit
  questions), not the `"reply with the word for N"` toy.
- **Bound it and validate at N≥3** (learnings §2.8 — a one-task canary hides the worst,
  timing-dependent failure). N=5–12 is a good range; keep ≤ ~16 concurrent (you are the
  governor — no per-run cap exists).
- **Confirm the four success signals:**
  1. **Children persist** after the run — `GET /v1/sessions/{parent}/child_sessions`
     still lists them (not deleted), and they remain nested in the Subagents panel.
  2. **No runner retry-storm** — the whole point of Fix 4; the runner log stays quiet
     (no `missing_work_entry` / `subagent_delivery_not_confirmed` flood) after children
     finish.
  3. **Genuine-run signature** per child — ≥1 assistant message + non-zero tokens
     (~17.7k for a short turn), not the inert seed-only shell (0 assistant msgs, `None`
     tokens, `host_id` None).
  4. **Correct synthesized output** returned to the orchestrator; the fan-out never
     enters sybil's context.
- **Inject the parent id:** `OMNIGENT_PARENT_SESSION_ID=<conv id from
  sys_session_get_info>` on the run command — it is NOT ambient in the `sys_os_shell`
  subprocess.
- **Do not tear down — leaving the children up IS the test.** Sweep them manually
  afterward if you want a clean tree (`DELETE /v1/sessions/{id}` per child).

If persistence **and** no-storm both hold, that confirms learnings §8 **Tier-2 is
"done"** — then do the fold-in below.

## Next session — follow-on once the test passes
- **Learnings fold-in** (`doc/dynamic-workflows-learnings.md`, bureau — prose, sybil
  authors directly): reframe §2.1/§2.2 from "teardown is mandatory" → "teardown
  optional; persistence is the default since Fix 4," and move §8 Tier-2 from "one fix
  away" → "done (verified at N=…)." Record the persistence test's N and the four
  signals as the evidence.

---

## Two repos (this work spans both)

- **Fork — runner code:** `/Users/junek/workspace/omnigent`. `origin = JuneKelly/omnigent`,
  `upstream = omnigent-ai/omnigent`. Branch **`sybil/dynamic-workflows`**, off clean
  `main` (`ab63662d`). Holds Fix 4 + Item A: `3591e95a`, `7ec56330`, `b376ccdd`.
  Local-only; not pushed. (An unrelated dirty `web/package-lock.json` lives in the tree —
  not ours; leave it.)
- **Bureau — skill/docs/learnings:** `/Users/junek/bureau`. Branch **`dynamic-workflow`**.
  Holds the SKILL.md persistence change (`30ec5e9`) + the docs/learnings. Local-only.

Note: reference symbols, not line numbers — fork anchors have shifted multiple times.
`sys_os_read`/`sys_os_edit` are scoped to the **bureau** root; read fork files via
`sys_os_shell` (sed/grep/git).

---

## Verified wire facts (durable — re-confirm in the server-up check, don't re-derive)

- **Create + seed a child:** `POST /v1/sessions` with `{agent_id, sub_agent_name,
  parent_session_id, title, initial_items:[<message item>]}`. Message item:
  `{"type":"message","data":{"role":"user","content":[{"type":"input_text","text":"…"}]}}`.
  (Create body is hidden from `openapi.json` but proven by repeated successful creates.)
  `POST /v1/sessions/{id}/events` takes the same body to steer a running session.
- **Read results:** `GET /v1/sessions/{id}/items?order=desc&limit=N` is flat OpenAI-style:
  `{object,data,first_id,last_id,has_more}`, `role`/`content` top-level; assistant text
  parts are `type:"output_text"`.
- **Persistence check:** `GET /v1/sessions/{parent}/child_sessions` lists children by
  `(kind=="sub_agent", parent_conversation_id)` with **no deleted/status filter** — so a
  non-deleted completed child still shows here (and in the Subagents panel). This is the
  query the persistence test asserts against. (After a `DELETE`, the child 404s and drops
  off this list.)
- **`status` `idle` is OVERLOADED:** means BOTH "created, seeded turn not dispatched yet"
  AND "turn finished." Completion is NOT `status != "running"` alone — gate on the turn
  having provably run (saw `running`, OR an assistant message exists). This is the **v3
  started-gate; do not regress it.** `status:"failed"` carries `last_task_error`.
- **Run vs inert child:** genuinely-run = ≥1 assistant message + non-zero tokens (~17.7k
  for a one-word turn). Inert = seed only, 0 assistant messages, tokens/cost `None`. NB
  `host_id` is `None` in the post-run snapshot too (host released) — use tokens +
  assistant message as the "it ran" signal.
- **Parent id is NOT ambient:** `OMNIGENT_SESSION_ID` is empty in the `sys_os_shell`
  subprocess. Inject `OMNIGENT_PARENT_SESSION_ID=<your conv id from sys_session_get_info>`
  on the run command. Required-or-bail.
- **REST-created children are invisible to `sys_session_*`** (sybil's MCP tools — no
  linkage there), but ARE visible via the REST `child_sessions` query above. Manual
  cleanup only via `DELETE /v1/sessions/{id}` — a teardown probe must sweep its own
  children.
- **Workers have no standalone `agent_id`** — explorer/builder/drone/reviewer exist only
  as sub-agents in sybil's spec tree, resolved via `parent_session_id + sub_agent_name`.
- **Re-runs collide:** `(parent, title)` must be unique or `POST /v1/sessions` → 500
  (`NameAlreadyExistsError`). Use run-scoped titles, e.g. `wf-{runid}-task-{i}`.
- **SSE** `GET /v1/sessions/{id}/stream?idle=true` is a live-tail with no history replay
  (`idle` = presence flag, not completion). Poll the snapshot; don't await SSE.
- **Teardown:** `DELETE /v1/sessions/{id}` → `{deleted:true}`.

---

## Platform warts — current status

1. ✅ **REST-created parented children get no parent work-entry → runner retry-storm.**
   Storm **mitigated by Fix 4** (204-ack instead of 503). The work-entry is still not
   registered on REST create, so inbox *delivery* still doesn't happen — the program
   reads child items directly (it never relied on delivery).
2. ✅ **Runner retried an undeliverable terminal status indefinitely.** Fixed —
   non-deliverable `missing_work_entry`-class status now 204-acks; only the genuinely
   transient `missing_parent_inbox` (entry present, not yet delivered) still retries.
3. ⏳ **`status` `idle` overloaded** (pre-dispatch vs finished). The skill's v3
   started-gate handles it; a distinct `created`/`queued` state would let clients drop
   the workaround. Nice-to-have.
4. ⏳ **Title collision is a 500, should be 409** (`NameAlreadyExistsError`). Run-scoped
   titles dodge it; low priority.

---

## Operating reminders for the next session

- **Address the operator as Junebug.**
- **Roster preflight first:** `command -v claude codex || true`. Full roster incl. Codex
  `reviewer` expected.
- **The server is patched and live (Fix 4 in).** If spawning a worker ever fails to
  *boot* (e.g. `ModuleNotFoundError`), the running server may be stale from a mid-flight
  reinstall — a fresh server+session clears it. Don't fixate on any hardcoded port; the
  proof the server is live is that your `sys_*` tools answer. Use `$RUNNER_SERVER_URL`
  for a base URL if needed.
- **Next session sybil DOES run the dynamic-workflow probe — that IS the test.**
  (Contrast: the runner *code* was validated by Junebug, not sybil.)
- **sybil does not write runner/source code** — any code/test change → `builder`/`drone`
  + Codex `reviewer`. Docs/skills (prose) are authored directly by sybil.
- **Validate fan-out at N≥3, never N=1** (learnings §2.8).
- **Commit locally only** — fork `sybil/dynamic-workflows`, bureau `dynamic-workflow`.
  No push, no PRs. The one merge that's yours is a fanout task→topic merge-back.

## Suggested skills for the next session

- **`dynamic-workflow`** — the skill under test; author a real `workflow.py` from the v4
  template and run it (persistence on).
- **`learning-store` / `learning-summarise`** — to fold the persistence test outcome into
  `doc/dynamic-workflows-learnings.md` (§2.1/§2.2 reframe, §8 Tier-2 → done).
- **`sybil:cross-review`** — only if the test surfaces a code/test fix needing a
  `builder` + Codex round.
