# Dynamic Workflows — Session Handoff

**Purpose:** start a fresh session and continue the dynamic-workflow work without
re-deriving everything. Working-state snapshot, not a design doc.

**Why this handoff exists:** the runner fix is **done and cross-reviewed** (local commits,
see below). We are handing off because the runtime hosting the last session went **stale
after a mid-flight tool reinstall** and can no longer spawn sub-agents. A **clean session on
a freshly-restarted server is required** to finish the two remaining items.

**Read these first (in order):**
1. `doc/dynamic-workflows-learnings.md` — the empirical record. Start with §2.1 / §2.2 (the
   teardown story), §7 (N=12 confirming re-run), §8 (viability verdict). The teardown story
   is the direct context for the persistence half that remains.
2. This file's **"Where things stand"** — the runner fix that already landed.
3. `doc/dynamic-workflows-feasibility.md` — original static-read design (background).

---

## TL;DR — what's done, what's left

- ✅ **Runner storm fix ("Fix 4") — DONE, cross-reviewed, committed locally** on
  `sybil/dynamic-workflows` in the **fork** (`/Users/junek/workspace/omnigent`). Two commits.
  Not pushed; `main` untouched.
- 🔁 **Item A — strengthen one tautological test — APPROVED by Junebug, NOT yet landed.** The
  dispatch couldn't run because the runtime degraded (below). First real task in the clean
  session. Code/test change → `builder` + Codex `reviewer`.
- ⏳ **Reinstall + server restart — Junebug's, in progress.** She is reinstalling omnigent
  from the local fork branch and will run the omnigent tests herself. **sybil runs no
  validation** (her explicit call; repo not dev-bootstrapped).
- ⏳ **Persistence half (SKILL.md, bureau repo) — NOT started, pending Junebug's go.** Prose/
  skill edit → sybil authors directly, no sub-agent. Must land **after** the runner fix is
  live, else the storm resurfaces.

---

## Two repos (this work spans both)

- **Fork — runner code:** `/Users/junek/workspace/omnigent`. `origin = JuneKelly/omnigent`,
  `upstream = omnigent-ai/omnigent`. Branch **`sybil/dynamic-workflows`**, derived from clean
  `main` (`ab63662d`). The runner fix lives here. **Not set up for local dev yet.**
- **Bureau — skill/docs/learnings:** `/Users/junek/bureau`. Branch **`dynamic-workflow`**. The
  SKILL.md persistence change + learnings updates land here.

Note: the old handoff's `runner/app.py` path is the **nested** `omnigent/runner/app.py` in
this fork's layout. Reference symbols, not line numbers — anchors have shifted twice already.

---

## Where things stand — the runner fix that landed

**What it is (Fix 4, the safety-net — NOT the old menu's fix 1 or 2):** when a REST-created
parented child finishes and has no parent work-entry, the runner now **204-acknowledges** the
non-deliverable terminal status instead of returning **503** — which kills the native
forwarder's forever-retry `missing_work_entry` storm. We deliberately chose this over
registering a work-entry on REST create (fix 1): smaller, and it does **not** wake a parent
that never dispatched the child (the opposite of "persist quietly").

**Commits on `sybil/dynamic-workflows` (local-only, not pushed):**
- `3591e95a fix(runner): acknowledge non-deliverable subagent terminal status instead of 503`
- `7ec56330 test(runner): update subagent no-work-entry assertions to 204 contract`
- diffstat: `omnigent/runner/app.py` + `tests/runner/test_app_sessions_native.py`
  (~31 ins / 43 del). Working tree has an **unrelated** dirty `web/package-lock.json` — not
  ours; leave it.

**Change shape (by symbol, since lines shift):**
- In `_subagent_delivery_not_confirmed_response` (was ~`app.py:7397`): dropped the
  `and not is_runner_known_subagent` qualifier so `if ack.entry is None: return None`. Only
  remaining 503 path becomes the **genuinely transient** `missing_parent_inbox` (entry
  present, not yet delivered) — which *should* still retry.
- Removed the now-dead `reason` ternary branch; removed the unused
  `_SUBAGENT_DELIVERY_MISSING_WORK_ENTRY` constant (verified unreferenced); removed the unused
  `is_runner_known_subagent` param + its single caller; rewrote the docstring.
- Test `test_known_subagent_status_without_work_entry_returns_503` → renamed `..._is_acknowledged`,
  asserts **204**; two stale comments refreshed (`test_...:15806`, `app.py:9752`).

**Cross-review (Codex, 2 rounds):** round 1 flagged the stale 503 test as blocking; round 2
**PASS, zero blockers.** Codex confirmed the renamed test is **not vacuous** — `POST
/v1/sessions` with `sub_agent_name` populates `_session_sub_agent_names` *without* registering
work, so it genuinely exercises the runner-known + no-work-entry path and the 204 assertion is
meaningful.

---

## ⚠️ THE BLOCKER that forced this handoff — degraded runtime

The server/runtime that hosted the last session is **stale after a mid-flight reinstall**:

- Spawning **any** sub-agent (builder/drone/explorer/reviewer) fails to **boot** with
  `ModuleNotFoundError: No module named 'omnigent.onboarding.harness_install'` — even though
  that module **exists and imports cleanly on disk** under the uv-tool python.
- Diagnosis: the **running server process is stale** (launched from pre-reinstall code, still
  in memory); disk has moved on. **Reads** (`sys_agent_list`, `sys_read_inbox`,
  `sys_list_models`, `sys_os_shell`) work because they don't fork; **spawning a worker forks
  from the stale process** and can't resolve the new module layout.
- A **clean session on the freshly-restarted server** clears this. That is the precondition
  for Item A and any further delegation.

**Two myths to NOT repeat (cost real time last session):**
1. **Don't fixate on port `:6767`** (or any hardcoded port from old docs). The proof a server
   is live is that your `sys_*` tools answer — read the runtime from the live session, not a
   curl to a guessed port. Use `$RUNNER_SERVER_URL` if you need a base URL.
2. **`runner_unavailable` ≠ global outage.** Last session it meant one specific **dead builder
   sub-agent session** whose own runner had gone offline. Don't try to resurrect a dead
   session — spawn a **fresh** worker.

---

## Remaining work (for the clean session)

### Item A — strengthen the tautological leak test (APPROVED, do first)
After Fix 4, `test_late_status_for_deleted_sub_agent_child_is_not_a_spurious_503` is
**tautological**: a late status now returns 204 regardless of the `.pop`, so the assertion
passes even if the leak-fix `.pop` were deleted. Reviewer's suggested hardening (Junebug
approved):
- Assert the child id is **absent** from `_session_sub_agent_names` after delete.
- Rename to `test_delete_session_drops_sub_agent_name_mapping`.
This is a **code/test change** → delegate to `builder` (same contract discipline), then Codex
`reviewer`, commit on `sybil/dynamic-workflows`. (Also a truly-unrelated stale
`missing_work_entry` mention at `test_...:8327` — log for a future broad cleanup, not urgent.)

### Reinstall + restart (Junebug's; gates A)
Junebug reinstalls omnigent from the local fork branch and restarts the server, then runs the
tests herself. **sybil performs no validation.** Once the server is fresh, the spawn blocker
above is gone.

### Item B — persistence half (SKILL.md, bureau) — pending Junebug's go
The runner fix kills the storm but does **not** itself make children persist. Persistence is
**free at the data layer** — `list_child_conversation_ids_by_parent` (sqlalchemy_store.py) has
**no status/deleted filter**, so a non-deleted completed child already renders; **no DB
migration**. The whole persistence change is: **stop force-deleting completed children in
`SKILL.md`** (B-1b teardown → optional; persistence becomes the documented default for
review-style runs). This is **prose/skill authoring → sybil editsit directly, no sub-agent.**
- **Sequencing:** land B **after** the runner fix is live. Persisting children while the old
  503-storming server is running would resurface the storm.
- **Skill edits are NOT hot-reloaded** — need a server+session restart to go live.
- **Then fold into learnings:** §2.1/§2.2 lose the "teardown is mandatory" framing; §8 Tier-2
  moves from "one fix away" → "done."

### Definition of done
Completed child agents remain visible in the sidebar after their turn finishes, with **no
runner retry-storm**, runner fix cross-reviewed (✅ done) and Item A landed, SKILL.md teardown
made optional, learnings updated. All committed locally (fork: `sybil/dynamic-workflows`;
bureau: `dynamic-workflow`) — **not pushed, no PRs.**

---

## The test hang Junebug saw (`test_runner_ownership.py` Timeout) — NOT ours
Confirmed from direct evidence, not a hunch:
- **Zero surface overlap:** greps of that test for `missing_work_entry`, `work_entry`,
  `external_session_status`, `sub_agent_name`, `subagent_delivery`, `is_runner_known_subagent`,
  `ack.entry` → none present.
- **Our diff doesn't touch it:** `main..HEAD` changed only `omnigent/runner/app.py` (subagent
  delivery-ack path) and `tests/runner/test_app_sessions_native.py`.
- **Signature is environmental:** integration harness spinning up real infra (`boxlite-runtime`,
  `egress-relay`, `claude-native-tool-relay`), MainThread parked in asyncio `selector.select`,
  a `pytest_rerunfailures … run_server … sock.accept()` thread blocked on a socket that never
  connects — a setup/handshake timeout, and it's under `pytest_rerunfailures` (flaky-prone).
- **Decisive check if doubted:** run that one test on clean `main` (before our two commits). If
  it hangs there too → definitively pre-existing/environmental.

---

## Verified wire facts (durable — re-confirm in the server-up check, don't re-derive)

- **Create + seed a child:** `POST /v1/sessions` with `{agent_id, sub_agent_name,
  parent_session_id, title, initial_items:[<message item>]}`. Message item:
  `{"type":"message","data":{"role":"user","content":[{"type":"input_text","text":"…"}]}}`.
  (Create body is hidden from `openapi.json` but proven by repeated successful creates.)
  `POST /v1/sessions/{id}/events` takes the same body to steer a running session.
- **Read results:** `GET /v1/sessions/{id}/items?order=desc&limit=N` is flat OpenAI-style:
  `{object,data,first_id,last_id,has_more}`, `role`/`content` top-level; assistant text parts
  are `type:"output_text"`.
- **`status` `idle` is OVERLOADED:** means BOTH "created, seeded turn not dispatched yet" AND
  "turn finished." Completion is NOT `status != "running"` alone — gate on the turn having
  provably run (saw `running`, OR an assistant message exists). This is the **v3 started-gate;
  do not regress it.** `status:"failed"` carries `last_task_error`.
- **Run vs inert child:** genuinely-run = ≥1 assistant message + non-zero tokens (~17.7k for a
  one-word turn). Inert = seed only, 0 assistant messages, tokens/cost `None`. NB `host_id` is
  `None` in the post-run snapshot too (host released) — use tokens + assistant message as the
  "it ran" signal.
- **Parent id is NOT ambient:** `OMNIGENT_SESSION_ID` is empty in the `sys_os_shell`
  subprocess. Inject `OMNIGENT_PARENT_SESSION_ID=<your conv id from sys_session_get_info>` on
  the run command. Required-or-bail.
- **REST-created children are invisible to `sys_session_*`** (no `parent_session_id` linkage).
  Cleanup only via `DELETE /v1/sessions/{id}` — a no-teardown probe must sweep its own children.
- **Workers have no standalone `agent_id`** — explorer/builder/drone/reviewer exist only as
  sub-agents in sybil's spec tree, resolved via `parent_session_id + sub_agent_name`.
- **Re-runs collide:** `(parent, title)` must be unique or `POST /v1/sessions` → 500
  (`NameAlreadyExistsError`). Use run-scoped titles, e.g. `wf-{runid}-task-{i}`.
- **SSE** `GET /v1/sessions/{id}/stream?idle=true` is a live-tail with no history replay
  (`idle` = presence flag, not completion). Poll the snapshot; don't await SSE.
- **Teardown:** `DELETE /v1/sessions/{id}` → `{deleted:true}`.

---

## Platform warts — status after this session's fix
1. ✅ **REST-created parented children get no parent work-entry → runner retry-storm.**
   **Mitigated by Fix 4** (204-ack instead of 503-storm). The work-entry is still not
   registered on REST create (we chose not to — fix 1), but the storm is gone.
2. ✅ **Runner retried an undeliverable terminal status indefinitely.** Fixed — non-deliverable
   `missing_work_entry`-class status now 204-acks; only transient `missing_parent_inbox` retries.
3. ⏳ **`status` `idle` overloaded** (pre-dispatch vs finished) — a distinct `created`/`queued`
   state would let clients drop the started-gate. Nice-to-have; not required for persistence.
4. ⏳ **Title collision is a 500, should be 409** (`NameAlreadyExistsError`). Run-scoped titles
   dodge it; low priority.

---

## Operating reminders for the next session
- **Address the operator as Junebug.**
- **Roster preflight first:** `command -v claude codex || true`. Both were on PATH last
  session (full roster incl. Codex `reviewer`) — but re-check, and remember a **fresh server**
  is the precondition for spawning workers at all (see blocker above).
- **sybil does not write runner code** — Item A is a code/test change → `builder` + Codex
  `reviewer`. Docs/skills (prose) are authored directly by sybil.
- **No validation by sybil this run** (Junebug's call) — she reinstalls + runs tests. The green
  gate for the runner fix was cross-review logic verification + greps, not a live test run.
- **Validate concurrency at N≥3, never N=1** — worst failure is timing-dependent (learnings
  §2.8) — *if* you run any probe (e.g. to confirm persistence after B).
- **Commit locally only** — fork `sybil/dynamic-workflows`, bureau `dynamic-workflow`. Do not
  push, do not open PRs. The one merge that's yours is a fanout task→topic merge-back.
- **Dead sessions from last run** (builder `conv_11058d25…` = failed; reviewer
  `conv_29d0105…`): gone with the stale server — **do not resurrect; spawn fresh.**

---

## Suggested skills for the next session
- **`sybil:cross-review`** — for Item A: verify the builder's test-hardening diff with the
  Codex `reviewer` against an explicit contract (assert id absent from `_session_sub_agent_names`
  after delete; rename the test). Loop until clean.
- **`sybil:investigate`** — only if something about the runner change needs re-mapping against
  the (reinstalled) fork; delegate read-only, synthesize from the report. Anchors have shifted
  twice — re-verify by symbol before trusting any line number.
- **`learning-store` / `learning-summarise`** — when Item B lands, to fold the verified outcome
  into `doc/dynamic-workflows-learnings.md` (§2.1/§2.2 reframe, §8 Tier-2 → done).
